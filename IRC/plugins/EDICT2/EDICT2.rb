# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# EDICT2 plugin
#
# The EDICT2 Dictionary File (edict2) used by this plugin comes from Jim Breen's JMdict/EDICT Project.
# Copyright is held by the Electronic Dictionary Research Group at Monash University.
#
# http://www.edrdg.org/jmdict/edict.html

require 'sequel'

require 'IRC/complex_regexp'
require 'IRC/IRCPlugin'
require 'IRC/LayoutableText'
require 'IRC/SequelHelpers'

IRCPlugin.remove_required 'IRC/plugins/EDICT2'
require 'IRC/plugins/EDICT2/parsed_entry'

class EDICT2
  include IRCPlugin
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
    require 'IRC/plugins/EDICT2/menu_entry'

    @language = @plugin_manager.plugins[:Language]
    @menu = @plugin_manager.plugins[:Menu]

    @db = database_connect("sqlite://#{(File.dirname __FILE__)}/edict2.sqlite", :encoding => 'utf8')

    @regexpable = load_dict(@db)
  end

  def beforeUnload
    @menu.evict_plugin_menus!(self.name)

    @regexpable = nil

    database_disconnect(@db)
    @db = nil

    @menu = nil
    @language = nil

    nil
  end

  def on_privmsg(msg)
    case msg.bot_command
    when :j
      word = msg.tail
      return unless word
      lookup_result_menu = lookup_menu(word)

      enamdict = @plugin_manager.plugins[:ENAMDICT]
      if lookup_result_menu.entries.empty? && enamdict
        enamdict_lookup_menu = enamdict.lookup_menu(word)
        unless enamdict_lookup_menu.entries.empty?
          msg.reply("No hits for #{lookup_result_menu.description}. Delegating to ENAMDICT.")
          lookup_result_menu.entries << enamdict_lookup_menu
        end
      end

      reply_with_menu(msg, lookup_result_menu)
    when :e
      word = msg.tail
      return unless word
      edict_lookup = group_results(keyword_lookup(split_into_keywords(word)))
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
    when :jr2
      word = msg.tail
      return unless word
      begin
        word = ComplexRegexp::strip_complex_whitespace(word)
        @language.replace_japanese_regex!(word)
        tree = ComplexRegexp::parse(word)
        plan = ComplexRegexp::program(tree)
        plan = ComplexRegexp::guard_names_to_symbols(plan, SUPPORTED_GUARDS)
        ComplexRegexp::check_types_nesting(ComplexRegexp::get_plan_types(plan)) do |type|
          !SUPPORTED_TYPES.include?(type)
        end
      rescue => e
        msg.reply("EDICT2 Regexp query error: #{e.message}")
        return
      end
      reply_with_menu(msg, generate_menu(lookup_complex_regexp2(plan), "\"#{word}\" in EDICT2"))
    end
  end

  def lookup_menu(word)
    variants = @language.variants([word], *Language::JAPANESE_VARIANT_FILTERS)
    lookup_result = group_results(lookup(variants))
    description = [
        wrap(word, '"'),
        wrap((variants-[word]).map { |w| wrap(w, '"') }.join(', '), '(', ')'),
        'in EDICT2'
    ].compact.join(' ')
    generate_menu(
        format_description_unambiguous(lookup_result),
        description
    )
  end

  def wrap(o, prefix=nil, postfix=prefix)
    "#{prefix}#{o}#{postfix}" unless o.nil? || o.empty?
  end

  def format_description_unambiguous(lookup_result)
    amb_chk_kanji = Hash.new(0)
    lookup_result.each do |e|
      amb_chk_kanji[e.japanese] += 1
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

      MenuEntry.new(description, e)
    end

    Menu::MenuNodeSimple.new(name, menu)
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

  def group_results(entries)
    gs = entries.group_by {|e| e.edict_text_id}
    gs.sort_by do |edict_text_id, _|
      edict_text_id
    end.map do |edict_text_id, g|
      japanese, reading = g.map {|p| [p.japanese, p.reading]}.transpose
      DatabaseGroupEntry.new(@db, :japanese => japanese.uniq.join(','), :reading => reading.uniq.join(','), :id => edict_text_id)
    end
  end

  # Looks up all entries that have any given word in any
  # of the specified columns and returns the result as an array of entries
  def lookup_impl(words, columns)
    condition = Sequel.or(columns.product([words]))

    dataset = @db[:edict_entry].where(condition).group_by(Sequel.qualify(:edict_entry, :id))

    standard_order(dataset).select(*DatabaseEntry::COLUMNS).to_a.map do |entry|
      DatabaseEntry.new(@db, entry)
    end
  end

  def lookup_complex_regexp(complex_regexp)
    regexps_kanji, regexps_kana, regexps_english = complex_regexp

    lookup_result = []

    if complex_regexp.size <= 1
      # Single condition. Add entry if either part matches it.
      regexps_kana = regexps_kanji
      @regexpable.each do |entry|
        word_kanji = entry.japanese
        kanji_matched = regexps_kanji.all? { |regex| regex =~ word_kanji }
        word_kana = entry.reading
        kana_matched = regexps_kana.all? { |regex| regex =~ word_kana }
        lookup_result << [entry, kanji_matched, kana_matched] if kanji_matched || kana_matched
      end
    else
      # Multiple conditions. Add entry, only if all of them match on respective entry parts.
      @regexpable.each do |entry|
        word_kanji = entry.japanese
        next unless regexps_kanji.all? { |regex| regex =~ word_kanji }
        word_kana = entry.reading
        next unless regexps_kana.all? { |regex| regex =~ word_kana }
        lookup_result << [entry, true, true]
      end
    end

    gs = lookup_result.group_by {|e, _, _| e.edict_text_id}

    if regexps_english
      @db[:edict_text].where(:id => gs.keys).select(:id, :raw).each do |h|
        text_english = h[:raw]
        next if regexps_english.all? { |regex| regex =~ text_english }
        gs.delete(h[:id])
      end
    end

    group_matched_entries(gs)
  end

  def group_matched_entries(gs)
    gs.sort_by do |edict_text_id, _|
      edict_text_id
    end.map do |edict_text_id, g|
      japanese, reading = g.map do |p, kanji_matched, kana_matched|
        [(p.japanese if kanji_matched), (p.reading if kana_matched)]
      end.transpose
      japanese = japanese.compact
      reading = reading.compact
      japanese = g.map {|p, _, _| p.japanese} if japanese.empty?
      #reading = g.map {|p, _, _| p.reading} if reading.empty?
      [
          DatabaseGroupEntry.new(
              @db,
              :japanese => japanese.uniq.join(','),
              :reading => reading.uniq.join(','),
              :id => edict_text_id,
          ),
          !(japanese - reading).empty?,
          !reading.empty?,
      ]
    end
  end

  SUPPORTED_TYPES = [
      [],
      [:japanese],
      [:reading],
      [:full],
      [:romaji],
      [:japanese, :romaji],
      [:reading, :romaji],
      [:full, :romaji],
  ]

  # noinspection RubyStringKeysInHashInspection
  SUPPORTED_GUARDS = {
      'japanese' => :japanese,
      '0' => :japanese,
      'reading' => :reading,
      '1' => :reading,
      'full' => :full,
      '2' => :full,
      'romaji' => :romaji,
  }

  def lookup_complex_regexp2(plan)
    group_depths = ComplexRegexp::get_plan_group_depths(plan)

    # For user convenience, :romaji guard at the top level is a context-free fetcher.
    # :romaji guard inside a capture group is a kana->romaji converter of group contents,
    # so rename it to :romaji_inline.
    group_depths.zip(plan).each do |depth, cmd|
      if depth > 0 && cmd[3] == :FunctionalGuard && cmd[4] == :romaji
        cmd[4] = :romaji_inline
      end
    end

    plan = ComplexRegexp::replace_context_free_fetchers(plan, [:japanese, :reading, :full, :romaji])

    complex_regexp_full = nil
    lookup_result = []

    types = ComplexRegexp::get_plan_types(plan)

    if types.all?(&:empty?)
      # No guards. Add entry if either part matches it.
      complex_regexp = ComplexRegexp::InterpretingExecutor.new(plan)
      @regexpable.each do |entry|
        word_kanji = entry.japanese
        kanji_matched = complex_regexp.perform_match(word_kanji)
        word_kana = entry.reading
        kana_matched = complex_regexp.perform_match(word_kana)
        lookup_result << [entry, kanji_matched, kana_matched] if kanji_matched || kana_matched
      end
    else
      # Guards present. Add entry, only if all of them match on respective entry parts.

      # Let's leave out steps that need full entry text, for now.
      plan_full, plan = ComplexRegexp::plan_split(plan) do |_, _, _, match_type, param|
        match_type == :FunctionalGuard && param == :full
      end

      unless plan_full.empty?
        initial = plan_full.first
        if initial[3] == :FunctionalGuard && initial[4] == :full
          complex_regexp_full = InterpretingExecutorForEntry.new(plan_full, @language)
        else
          raise "Bug! Plan for full match doesn't start with full guard"
        end
      end

      complex_regexp = InterpretingExecutorForEntry.new(plan, @language)
      @regexpable.each do |entry|
        next unless complex_regexp.perform_match(entry.japanese, entry)
        lookup_result << [entry, true, true]
      end
    end

    gs = lookup_result.group_by {|e, _, _| e.edict_text_id}

    if complex_regexp_full
      # So we had guards for full text match too.
      # Let's fetch entries in batch, it's faster that way.
      @db[:edict_text].where(:id => gs.keys).select(:id, :raw).each do |h|
        text_english = h[:raw]
        next if complex_regexp_full.perform_match(text_english)
        gs.delete(h[:id])
      end
    end

    group_matched_entries(gs)
  end

  # Looks up all entries that contain all given words in english text
  def keyword_lookup(words)
    return [] if words.empty?

    words = words.uniq.map(&:to_s)

    english_ids = @db[:edict_english].where(Sequel.qualify(:edict_english, :text) => words).select(:id).to_a.flat_map {|h| h.values}

    return [] unless english_ids.size == words.size

    text_ids = @db[:edict_entry_to_english].where(Sequel.qualify(:edict_entry_to_english, :edict_english_id) => english_ids).group_and_count(Sequel.qualify(:edict_entry_to_english, :edict_text_id)).having(:count => english_ids.size).select_append(Sequel.qualify(:edict_entry_to_english, :edict_text_id)).to_a.map {|h| h[:edict_text_id]}

    dataset = @db[:edict_entry].where(Sequel.qualify(:edict_entry, :edict_text_id) => text_ids).select(*DatabaseEntry::COLUMNS)

    standard_order(dataset).to_a.map do |entry|
      DatabaseEntry.new(@db, entry)
    end
  end

  def standard_order(dataset)
    dataset.order_by(Sequel.qualify(:edict_entry, :id))
  end

  def split_into_keywords(word)
    ParsedEntry.split_into_keywords(word).uniq
  end

  def load_dict(db)
    versions = db[:edict_version].to_a.map {|x| x[:id]}
    unless versions.include?(ParsedEntry::VERSION)
      raise "The database version #{versions.inspect} of #{db.uri} doesn't correspond to this version #{[ParsedEntry::VERSION].inspect} of plugin. Rerun convert.rb."
    end

    regexpable = db[:edict_entry].select(*DatabaseEntry::COLUMNS).to_a

    regexpable.map do |entry|
      DatabaseEntry.new(db, entry)
    end
  end

  class DatabaseGroupEntry
    attr_reader :japanese, :reading, :simple_entry, :id

    def initialize(db, pre_init)
      @db = db

      @japanese = pre_init[:japanese]
      @reading = pre_init[:reading]
      @simple_entry = @japanese == @reading
      @id = pre_init[:id]
    end

    def raw
      @db[:edict_text].where(:id => @id).select(:raw).first[:raw]
    end

    def to_s
      self.raw
    end
  end

  class DatabaseEntry
    attr_reader :japanese, :reading, :simple_entry, :id, :edict_text_id
    FIELDS = [:japanese, :reading, :simple_entry, :id, :edict_text_id]
    COLUMNS = FIELDS.map {|f| Sequel.qualify(:edict_entry, f)}

    def initialize(db, pre_init)
      @db = db

      @japanese = pre_init[:japanese]
      @reading = pre_init[:reading]
      @simple_entry = pre_init[:simple_entry]
      @id = pre_init[:id]
      @edict_text_id = pre_init[:edict_text_id]
    end

    def raw
      @db[:edict_text].where(:id => @edict_text_id).select(:raw).first[:raw]
    end

    def to_s
      self.raw
    end
  end

  class InterpretingExecutorForEntry < ComplexRegexp::InterpretingExecutor
    def initialize(program, language)
      super(program)
      @language = language
    end

    def call_guard(name, text, guard_context, regex)
      case name
        when :japanese
          regex.match(guard_context.japanese)
        when :reading
          regex.match(guard_context.reading)
        when :full
          regex.match(guard_context.raw)
        when :romaji
          regex.match(@language.kana_to_romaji(guard_context.reading))
        when :romaji_inline
          regex.match(@language.kana_to_romaji(text))
        else
          raise "Unsupported guard #{name}"
      end
    end
  end
end
