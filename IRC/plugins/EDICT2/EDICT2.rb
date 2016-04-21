# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# EDICT2 plugin
#
# The EDICT2 Dictionary File (edict2) used by this plugin comes from Jim Breen's JMdict/EDICT Project.
# Copyright is held by the Electronic Dictionary Research Group at Monash University.
#
# http://www.csse.monash.edu.au/~jwb/edict.html

require 'rubygems'
require 'bundler/setup'
require 'sequel'

require 'IRC/IRCPlugin'
require 'IRC/SequelHelpers'

class EDICT2 < IRCPlugin
  include SequelHelpers

  DESCRIPTION = 'An EDICT2 plugin.'
  COMMANDS = {
    :j => 'looks up a Japanese word in EDICT2',
    :e => 'looks up an English word in EDICT2',
    :jr => "searches Japanese words matching given regexp in EDICT2. \
See '.faq regexp'",
  }
  DEPENDENCIES = [:Language, :Menu]

  def afterLoad
    load_helper_class(:EDICT2Entry)

    @language = @plugin_manager.plugins[:Language]
    @menu = @plugin_manager.plugins[:Menu]

    @db = database_connect("sqlite://#{(File.dirname __FILE__)}/edict2.sqlite", :encoding => 'utf8')

    @hash_edict = load_dict(@db)
  end

  def beforeUnload
    @menu.evict_plugin_menus!(self.name)

    @hash_edict = nil

    database_disconnect(@db)
    @db = nil

    @menu = nil
    @language = nil

    unload_helper_class(:EDICT2Entry)

    nil
  end

  def on_privmsg(msg)
    case msg.bot_command
    when :j
      word = msg.tail
      return unless word
      variants = @language.variants([word], *Language::JAPANESE_VARIANT_FILTERS)
      lookup_result = lookup(variants)
      reply_with_menu(
          msg,
          generate_menu(
              format_description_unambiguous(lookup_result),
              [
                  wrap(word, '"'),
                  wrap((variants-[word]).map{|w| wrap(w, '"')}.join(', '), '(', ')'),
                  'in EDICT2',
              ].compact.join(' ')
          )
      )
    when :e
      word = msg.tail
      return unless word
      edict_lookup = keyword_lookup(split_into_keywords(word))
      reply_with_menu(msg, generate_menu(format_description_show_all(edict_lookup), "\"#{word}\" in EDICT2"))
    when :jr
      word = msg.tail
      return unless word
      begin
        complex_regexp = @language.parse_complex_regexp(word)
      rescue => e
        msg.reply("EDICT2 Regexp query error: #{e.message}")
        return
      end
      reply_with_menu(msg, generate_menu(lookup_complex_regexp(complex_regexp), "\"#{word}\" in EDICT2"))
    end
  end

  def wrap(o, prefix=nil, postfix=prefix)
    "#{prefix}#{o}#{postfix}" unless o.nil? || o.empty?
  end

  def format_description_unambiguous(lookup_result)
    amb_chk_kanji = Hash.new(0)
    amb_chk_kana = Hash.new(0)
    lookup_result.each do |e|
      amb_chk_kanji[e.japanese] += 1
      amb_chk_kana[e.reading] += 1
    end
    render_kanji = amb_chk_kanji.keys.size > 1

    lookup_result.map do |e|
      kanji_list = e.japanese
      render_kana = amb_chk_kanji[kanji_list] > 1

      [e, render_kanji, render_kana]
    end
  end

  def format_description_show_all(lookup_result)
    lookup_result.map do |entry|
      [entry, !entry.simple_entry, true]
    end
  end

  def generate_menu(lookup, name)
    menu = lookup.map do |e, render_kanji, render_kana|
      kanji_list = e.japanese

      description = if render_kanji && !kanji_list.empty?
                      render_kana ? "#{kanji_list} (#{e.reading})" : kanji_list
                    elsif e.reading
                      e.reading
                    else
                      '<invalid entry>'
                    end

      MenuNodeText.new(description, e)
    end

    MenuNodeSimple.new(name, menu)
  end

  def reply_with_menu(msg, result)
    @menu.put_new_menu(
        self.name,
        result,
        msg
    )
  end

  # Refined version of lookup_impl() suitable for public API use
  def lookup(words)
    lookup_impl(words, [:japanese, :reading_norm])
  end

  # Looks up all entries that have any given word in any
  # of the specified columns and returns the result as an array of entries
  def lookup_impl(words, columns)
    table = @hash_edict[:edict_entries]

    condition = Sequel.|(*words.map do |word|
      Sequel.or(columns.map { |column| [column, word] })
    end)

    dataset = table.where(condition).group_by(Sequel.qualify(:edict_entry, :id))

    standard_order(dataset).select(*EDICT2LazyEntry::COLUMNS).to_a.map do |entry|
      EDICT2LazyEntry.new(table, entry)
    end
  end

  def lookup_complex_regexp(complex_regexp)
    operation = complex_regexp.shift
    regexps_kanji, regexps_kana, regexps_english = complex_regexp

    lookup_result = []

    case operation
    when :union
      @hash_edict[:all].each do |entry|
        word_kanji = entry.japanese
        kanji_matched = regexps_kanji.all? { |regex| regex =~ word_kanji }
        word_kana = entry.reading
        kana_matched = regexps_kana.all? { |regex| regex =~ word_kana }
        lookup_result << [entry, !entry.simple_entry, kana_matched] if kanji_matched || kana_matched
      end
    when :intersection
      @hash_edict[:all].each do |entry|
        word_kanji = entry.japanese
        next unless regexps_kanji.all? { |regex| regex =~ word_kanji }
        word_kana = entry.reading
        next unless regexps_kana.all? { |regex| regex =~ word_kana }
        if regexps_english
          text_english = entry.raw.split('/', 2)[1] || ''
          next unless regexps_english.all? { |regex| regex =~ text_english }
        end
        lookup_result << [entry, !entry.simple_entry, true]
      end
    end

    lookup_result
  end

  # Looks up all entries that contain all given words in english text
  def keyword_lookup(words)
    return [] if words.empty?

    column = :text

    words = words.uniq

    table = @hash_edict[:edict_entries]
    edict_english = @hash_edict[:edict_english]
    edict_english_join = @hash_edict[:edict_english_join]

    condition = Sequel.|(*words.map do |word|
      { Sequel.qualify(:edict_english, column) => word.to_s }
    end)

    english_ids = edict_english.where(condition).select(:id).to_a.map {|h| h.values}.flatten

    return [] unless english_ids.size == words.size

    dataset = edict_english_join.where(Sequel.qualify(:edict_entry_to_english, :edict_english_id) => english_ids).group_and_count(Sequel.qualify(:edict_entry_to_english, :edict_entry_id)).join(:edict_entry, :id => :edict_entry_id).having(:count => english_ids.size)

    dataset = dataset.select_append(*EDICT2LazyEntry::COLUMNS)

    standard_order(dataset).to_a.map do |entry|
      EDICT2LazyEntry.new(table, entry)
    end
  end

  def standard_order(dataset)
    dataset.order_by(Sequel.qualify(:edict_entry, :id))
  end

  def split_into_keywords(word)
    EDICT2Entry.split_into_keywords(word).uniq
  end

  def load_dict(db)
    edict_version = db[:edict_version]
    edict_entries = db[:edict_entry]
    edict_english = db[:edict_english]
    edict_english_join = db[:edict_entry_to_english]

    versions = edict_version.to_a.map {|x| x[:id]}
    unless versions.include?(EDICT2Entry::VERSION)
      raise "The database version #{versions.inspect} of #{db.uri} doesn't correspond to this version #{[EDICT2Entry::VERSION].inspect} of plugin. Rerun convert.rb."
    end

    regexpable = edict_entries.select(*EDICT2LazyEntry::COLUMNS).to_a
    regexpable = regexpable.map do |entry|
      EDICT2LazyEntry.new(edict_entries, entry)
    end

    {
        :edict_entries => edict_entries,
        :edict_english => edict_english,
        :edict_english_join => edict_english_join,
        :all => regexpable,
    }
  end

  class EDICT2LazyEntry
    attr_reader :japanese, :reading, :simple_entry, :id, :edict_text_id
    FIELDS = [:japanese, :reading, :simple_entry, :id, :edict_text_id]
    COLUMNS = FIELDS.map {|f| Sequel.qualify(:edict_entry, f)}

    ID_FIELD = Sequel.qualify(:edict_entry, :id)

    def initialize(dataset, pre_init)
      @dataset = dataset

      @japanese = pre_init[:japanese]
      @reading = pre_init[:reading]
      @simple_entry = pre_init[:simple_entry]
      @id = pre_init[:id]
      @edict_text_id = pre_init[:edict_text_id]
    end

    def raw
      @dataset.where(ID_FIELD => @id).join(:edict_text, :id => :edict_text_id).select(:raw).first[:raw]
    end

    def to_s
      self.raw
    end
  end
end
