# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# Direct Client-to-Client chat worker

class DCCBot
  attr_reader :last_sent, :last_received, :start_time
  attr_accessor :caller_info, :credentials, :authorities

  def initialize(socket, dcc_plugin, parent_bot)
    @socket = socket
    @dcc_plugin = dcc_plugin
    @parent_bot = parent_bot

    @last_sent = nil
    @last_received = nil
    @start_time = Time.now

    @caller_info = @credentials = @authorities = nil
  end

  def user
    @parent_bot.user
  end

  def find_user_by_msg(msg)
    @parent_bot.find_user_by_msg(msg)
  end

  def find_user_by_nick(nick)
    @parent_bot.find_user_by_nick(nick)
  end

  def find_user_by_uid(name)
    @parent_bot.find_user_by_uid(name)
  end

  def serve
    log(:log, "Starting interaction with #{@caller_info}")

    begin
      self.dcc_send("Hello! You're authorized as: #{authorities.join(' ')}; Credentials: #{credentials.join(' ')}")
      @socket.flush

      #until @socket.eof? do # for some reason blocks until user sends several lines.
      while (raw = @socket.gets) do
        self.receive(raw)
        # improve latency a bit, by flushing output stream,
        # which was probably written into during the process
        # of handling received data
        @socket.flush
      end
    ensure
      log(:log, "Stopping interaction with #{@caller_info}")
    end
  end

  def close
    @socket.close
  end

  def receive(raw)
    @watch_time = Time.now

    raw = encode raw
    @last_received = raw

    log(:in, raw)

    begin
      @dcc_plugin.dispatch(DCCMessage.new(self, raw.chomp, @authorities.first))
    rescue Exception => e
      log(:error, "#{e.inspect} #{e.backtrace.join("\n")}")
    end
  end

  def dcc_send(raw)
    if raw.instance_of?(Hash)
      return raw if raw[:truncated] #already truncated
      #opts = raw
      raw = raw[:original]
    else
      #opts = {:original => raw}
    end
    raw = encode raw.dup

    #char-per-char correspondence replace, to make the returned count meaningful
    raw.gsub!(/[\r\n]/, ' ')
    raw.strip!

    @last_sent = raw

    log(:out, raw)

    @socket.write "#{raw}\r\n"
  end

  TIMESTAMP_MODE = {:log => '=', :in => '>', :out => '<', :error => '!'}

  def log(mode, text)
    puts "#{TIMESTAMP_MODE[mode]}DCC#{start_time.to_i}: #{Time.now}: #{text}"
  end

  # Checks to see if a string looks like valid UTF-8.
  # If not, it is re-encoded to UTF-8 from assumed CP1252.
  # This is to fix strings like "abcd\xE9f".
  def encode(str)
    str.force_encoding('UTF-8')
    unless str.valid_encoding?
      str.force_encoding('CP1252').encode!('UTF-8', {:invalid => :replace, :undef => :replace})
    end
    str
  end
end
