# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# Hello plugin

class Hello < IRCPlugin
  Description = "Says hello."
  Dependencies = [ :Language ]

  Hello = [
    'おはよう',
    'おはようございます',
    'こんにちは',
    'こんばんは',
    'さようなら',
    'おやすみ',
    'おやすみなさい',
    'もしもし',
    'やっほー',
    'ハロー'
  ]

  def afterLoad
    @l = @bot.pluginManager.plugins[:Language]
  end

  def beforeUnload
    @l = nil
  end

  def on_privmsg(msg)
    tail = msg.message.gsub(/^\s*#{@bot.user.nick}\s*[:>,]?\s+/, '').gsub(/[\s!?！？〜\.。]/, '').strip
    reply_index = self.class::Hello.find_index { |i| @l.hiragana(i) == @l.hiragana(@l.kana(tail)) }
    msg.reply(self.class::Hello[reply_index]) if reply_index
  end
end
