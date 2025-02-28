#!/usr/bin/env ruby
# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# KANJIDIC2 converter
#
# Converts the KANJIDIC2 file to a marshalled hash, readable by the KANJIDIC2 plugin.
# When there are changes to KANJIDICEntry or KANJIDIC2 is updated, run this script
# to re-index (./convert.rb), then reload the KANJIDIC2 plugin (!load KANJIDIC2).

require 'nokogiri'

(File.dirname(__FILE__) +'/../../../').tap do |lib_dir|
  $LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
end

require 'IRC/plugins/KANJIDIC2/database_entry'

class KANJIDIC2
class Converter
  attr_reader :hash

  def initialize(kanjidic_file, krad_file, gsf_file)
    @kanjidic_file = kanjidic_file
    @krad_file = krad_file
    @gsf_file = gsf_file

    @kanji = {}
    @code_skip = {}
    @stroke_count = {}
    @misc = {}
    @kanji_parts = {}
    @gsf_order = {}

    @hash = {}
    @hash[:kanji] = @kanji
    @hash[:code_skip] = @code_skip
    @hash[:stroke_count] = @stroke_count
    @hash[:misc] = @misc
    @hash[:kanji_parts] = @kanji_parts
    @hash[:gsf_order] = @gsf_order
    @hash[:version] = DatabaseEntry::VERSION
  end

  def read_krad_file
    File.open(@krad_file, 'r') do |io|
      io.each_line do |line|
        line.chomp!.strip!

        # drop comments and empty lines
        next if line.nil? || line.empty? || line.start_with?('#')

        # 𪀯 : 一 ノ ⺌ 灬 鳥
        md = line.match(/^(.) : (.*)$/)

        raise "Failed to parse kradfile line: #{line}" if md.nil?

        kanji = md[1]
        parts = md[2].gsub(/\s/, '')

#        if parts.size == 1
#          put_to_hash(@visual_equiv, parts, kanji)
#        end

        @kanji_parts[kanji] = parts
      end
    end
  end

  def read
    read_gsf_file

    # Compute visual equivalents reverse lookup for radicals.
    visual_equivalents = {}
    DatabaseEntry::KANGXI_SEARCH_RADICALS.each do |radicals|
      radicals.each do |radical|
        visual_equivalents.merge!({radical => radicals}) do |_, oldval, newval|
          oldval | newval
        end
      end
    end

    # No point in keeping 1-to-1 correspondence.
    visual_equivalents.delete_if do |_, equivalents|
      equivalents.size <= 1
    end

    reader = Nokogiri::XML::Reader(File.open(@kanjidic_file, 'r'))

    reader.each do |node|
      if node.node_type.eql?(Nokogiri::XML::Reader::TYPE_ELEMENT) && 'character'.eql?(node.name)
        parsed = Nokogiri::XML(node.outer_xml)

        entry = DatabaseEntry.new
        fill_entry(entry, parsed.child)

        @kanji[entry.kanji] = entry

        entry.code_skip.each do |skip|
          put_to_hash(@code_skip, skip, entry)
          put_to_hash(@misc, chk_term(skip), entry)
          put_to_hash(@misc, chk_term("P#{skip}"), entry)
          skips = skip.split(/-/)
          throw "Bug! Invalid skip code: #{skip}" unless skips.size == 3
          put_to_hash(@misc, chk_term("P#{skips[0]}"), entry)
          put_to_hash(@misc, chk_term("P*-#{skips[1]}"), entry)
          put_to_hash(@misc, chk_term("P#{skips[0]}-#{skips[1]}"), entry)
          put_to_hash(@misc, chk_term("P*-*-#{skips[2]}"), entry)
        end

        put_to_hash(@stroke_count, entry.stroke_count.to_s, entry)
        put_to_hash(@misc, chk_term("S#{entry.stroke_count.to_s}"), entry)

        put_to_hash(@misc, chk_term("G#{entry.grade}"), entry) if entry.grade

        put_to_hash(@misc, chk_term("J#{entry.jlpt}"), entry) if entry.jlpt

        put_to_hash(@misc, chk_term("C#{entry.radical_number}"), entry)

        DatabaseEntry::KANGXI_SEARCH_RADICALS[entry.radical_number-1].each do |rad|
          put_to_hash(@misc, chk_term("C#{rad}"), entry)
          put_to_hash(@misc, chk_term("PP#{rad}"), entry)
        end

        put_to_hash(@misc, chk_term("F#{entry.freq}"), entry) if entry.freq

        put_to_hash(@misc, chk_term("FG#{@gsf_order[entry.kanji]}"), entry) if @gsf_order[entry.kanji]

        if @kanji_parts[entry.kanji]
          @kanji_parts[entry.kanji].each_char do |part|
            # Put each part with its visual equivalents, where known.
            (visual_equivalents[part] || [part]).each do |tmp|
              put_to_hash(@misc, chk_term("PP#{tmp}"), entry)
            end
          end
        end

        get_misc_search_terms(entry).each do |term|
          put_to_hash(@misc, term, entry)
        end
      end
    end
  end

  private

  def read_gsf_file
    idx = 1
    File.open(@gsf_file, 'r') do |io|
      io.each_line do |line|
        line.chomp!.strip!

        # "的 2890000000"
        md = line.match(/^(.) \d+$/)

        raise "Failed to parse GSF line: #{line}" if md.nil?

        kanji = md[1]

        # We assume, that kanji are already ordered in file by frequency descending.
        @gsf_order[kanji] = idx
        idx += 1
      end
    end
  end

  def fill_entry(entry, node)
    entry.kanji = node.css('literal').first.text

    raise "Kanji is not a single char #{entry.kanji}" unless entry.kanji.size == 1

    entry.radical_number = node.css('radical rad_value[rad_type="classical"]').first.text.to_i

    entry.code_skip = node.css('query_code q_code[qc_type="skip"]').map {|n| n.text.strip}

    misc = node.css('misc').first

    grade = misc.css('grade').first
    entry.grade = grade ? grade.text.to_i : nil

    raise "Unknown kanji grade: #{entry.grade}" unless entry.grade.nil? || (1..10).include?(entry.grade)

    jlpt = misc.css('jlpt').first
    entry.jlpt = jlpt ? jlpt.text.to_i : nil

    raise "Unknown kanji JLPT level: #{entry.jlpt}" unless entry.jlpt.nil? || (1..4).include?(entry.jlpt)

    entry.stroke_count = misc.css('stroke_count').first.text.to_i

    freq = misc.css('freq').first
    entry.freq = freq ? freq.text.to_i : nil

    reading_meaning = node.css('reading_meaning').first

    unless reading_meaning
      entry.readings = entry.meanings = {}
      return
    end

    rm_groups = reading_meaning.css('rmgroup')
    case rm_groups.size
    when 0
      raise "Error in entry #{entry.kanji}. 'reading_meaning' node must contain one 'rmgroup' node."
    when 1
      # (pinyin) shen2 (korean_r) sin (korean_h) 신 (ja_on) シン ジン (ja_kun) かみ かん- こう-
      entry.readings = rm_groups.first.css('reading').each_with_object(Hash.new) do |reading, hash|
        key = reading['r_type'].to_sym
        txt = reading.text
        txt = txt.strip.split(' ')
        hash[key] ||= []
        hash[key] |= (txt)
      end

      # :korean_r is a waste of space, b/c it's not always correct,
      # and we can recompute it from korean_h. removing it.
      entry.readings.delete(:korean_r)

      reading_meaning.css('nanori').each_with_object(entry.readings) do |n, hash|
        hash[:nanori] ||= []
        hash[:nanori] << n.text.strip
      end

      entry.meanings = reading_meaning.css('meaning').each_with_object(Hash.new) do |meaning, hash|
        lang = meaning['m_lang'] || :en
        key = lang.to_sym
        txt = meaning.text.strip
        hash[key] ||= []
        hash[key] << txt
      end

      # we don't actually use other languages yet. free some memory.
      entry.meanings.delete_if {|lang, _| lang != :en}
    else
      raise 'This plugin should be rewritten to properly display more than one reading/meaning group.'
    end
  end

  def put_to_hash(hash, key, entry)
    hash[key] ||= []
    hash[key] |= [entry]
  end

  def chk_term(term)
    tmp = DatabaseEntry.split_into_keywords(term)
    unless tmp.size == 1 && term.size.eql?(tmp[0].size)
      raise "Bug! Term '#{term}' should survive DatabaseEntry.split_into_keywords(). Modify it appropriately."
    end
    tmp[0]
  end

  def get_misc_search_terms(entry)
    result = []
    kun = entry.readings[:ja_kun]
    if kun
      result |= kun.map do |r|
        DatabaseEntry.get_japanese_stem(r)
      end
    end

    r = entry.readings
    m = entry.meanings
    [r[:ja_on], r[:pinyin], r[:korean_h], m[:en]].each do |terms|
      next unless terms
      result |= terms.map {|term| DatabaseEntry.split_into_keywords(term)}.flatten
    end

    result
  end
end
end

def marshal_dict(dict, krad_dict, gsf_dict, marshal_file)
  ec = KANJIDIC2::Converter.new("#{(File.dirname __FILE__)}/#{dict}",
                             "#{(File.dirname __FILE__)}/#{krad_dict}",
                             "#{(File.dirname __FILE__)}/#{gsf_dict}")

  print "Indexing #{krad_dict.upcase}..."
  ec.read_krad_file
  puts 'done.'

  print "Indexing #{dict.upcase}..."
  ec.read
  puts 'done.'

  print "Marshalling #{marshal_file.upcase}..."
  File.open("#{(File.dirname __FILE__)}/#{marshal_file}", 'w') do |io|
    Marshal.dump(ec.hash, io)
  end
  puts 'done.'
end

marshal_dict('kanjidic2.xml', 'kradfile-u.txt', 'gsf.txt', 'kanjidic2.marshal')
