#!/usr/bin/env ruby
# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# Daijirin converter
#
# Converts the Daijirin file to a marshalled hash, readable by the Daijirin plugin.
# When there are changes to DaijirinEntry or Daijirin is updated, run this script
# to re-index (./convert.rb), then reload the Daijirin plugin (!load Daijirin).

$VERBOSE = true

require 'iconv'
require 'yaml'
require_relative 'DaijirinEntry'

class DaijirinEntry
  def post_parse
    # Do nothing. This is to prevent @raw cleanup after parsing,
    # b/c we need to marshal it first.
  end
end

class DaijirinConverter
  attr_reader :hash

  def initialize(sourceFile)
    @source_file = sourceFile
    @hash = {}
    @hash[:kanji] = {}
    @hash[:kana] = {}
    @hash[:english] = {}
    @all_entries = []
    @hash[:all] = @all_entries
    @hash[:version] = DaijirinEntry::VERSION

    # Duplicated two lines from ../Language/Language.rb
    @kata2hira = YAML.load_file("../Language/kata2hira.yaml") rescue nil
    @katakana = @kata2hira.keys.sort_by{|x| -x.length}
  end

    def read
      puts @source_file
      i = 0

      parent_entry = nil

      File.open(@source_file, 'r') do |io|
        lines = []
        io.each_line do |l|
          unless l[0..3] == '----'
            lines << l.chomp
            next
          end
          lns = lines
          lines = []

          puts "------ #{i}"
          i+=1

          if lns[0][0..1] == '――'
            next unless parent_entry
            entry = DaijirinEntry.new(lns, parent_entry)

            next if entry.parse == :skip

            # Add current entry as a child, since it was parsed successfully
            parent_entry.add_child!(entry)
          else
            entry = DaijirinEntry.new(lns)
            parent_entry = entry

            if entry.parse == :skip
              parent_entry = nil
              next
            end
          end

          entry_added = false

          entry.kanji_for_search.each do |x|
            (@hash[:kanji][x] ||= []) << entry
            entry_added = true
          end

          if entry.kana
            hiragana = hiragana(entry.kana)
            (@hash[:kana][hiragana] ||= []) << entry
            entry_added = true
          end

          if entry.english
            entry.english.each do |x|
              (@hash[:english][x.downcase.strip] ||= []) << entry
              entry_added = true
            end
          end

          @all_entries << entry if entry_added
        end
      end
    end

  def sort
    count = 0
    @all_entries .sort_by!{|e| e.sort_key_string }
    @all_entries .each do |e|
      e.sort_key = count
      # Take this opportunity to reorder all children,
      # so that they'll be output nicely in reference lists.
      e.children.sort_by!{|e| e.reference } if e.children
      count += 1
    end
  end

  # Based on method from ../Language/Language.rb
  def hiragana(katakana)
    hiragana = katakana.dup
    @katakana.each{|k| hiragana.gsub!(k, @kata2hira[k])}

    hiragana
  end
end

ec = DaijirinConverter.new("#{(File.dirname __FILE__)}/daijirin")

print "Indexing Daijirin..."
ec.read
puts "done."

print "Sorting Daijirin..."
ec.sort
puts "done."

print "Marshalling hash..."
File.open("#{(File.dirname __FILE__)}/daijirin.marshal", 'w') do |io|
  Marshal.dump(ec.hash, io)
end
puts "done."
