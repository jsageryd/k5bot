# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# Loader plugin loads or reloads plugins

require_relative '../../IRCPlugin'

class Loader < IRCPlugin
  Description = "Loads, reloads, and unloads plugins."
  Commands = {
    :load => "loads or reloads specified plugin",
    :unload => "unloads specified plugin",
    # :reload_core => "reloads core files"
  }

  def on_privmsg(msg)
    case msg.botcommand
    when :load
      return unless msg.tail
      msg.tail.split.each do |name|
        exists = !!(@bot.pluginManager.plugins[name.to_sym])
        unloadSuccessful = !!(@bot.pluginManager.unload_plugin name)
        if unloadSuccessful || !exists
          pconf = @bot.config[:plugins].find { |i| i.is_a?(Hash) ? (i.keys && name.to_sym == i.keys.first.to_sym) : name.to_sym == i.to_sym }
          config = pconf.is_a?(Hash) ? pconf.values.first : {}
          if @bot.pluginManager.load_plugin(name, config)
            msg.reply "'#{name}' #{'re' if exists}loaded."
          else
            msg.reply "Cannot #{'re' if exists}load '#{name}'."
          end
        else
          msg.reply "Cannot reload '#{name}'."
        end
      end
    when :unload
      return unless msg.tail
      msg.tail.split.each do |name|
        if name.eql? 'Loader'
          msg.reply "Refusing to unload the loader plugin."
          next
        end
        if @bot.pluginManager.unload_plugin name
          msg.reply "'#{name}' unloaded."
        else
          msg.reply "Cannot unload '#{name}'."
        end
      end
    when :reload_core
      load 'IRC/IRCBot.rb'
      load 'IRC/IRCChannel.rb'
      load 'IRC/IRCChannelPool.rb'
      load 'IRC/IRCFirstListener.rb'
      load 'IRC/IRCListener.rb'
      load 'IRC/IRCMessage.rb'
      load 'IRC/IRCMessageRouter.rb'
      load 'IRC/IRCPlugin.rb'
      load 'IRC/IRCPluginManager.rb'
      load 'IRC/IRCUser.rb'
      load 'IRC/IRCUserPool.rb'
      msg.reply "Core files reloaded."
    end
  end
end
