# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

require 'monitor'

class Timer
  def initialize(interval, &handler)
    raise ArgumentError, "Interval less than zero" if interval < 0
    extend MonitorMixin
    @handler = handler
    @interval = interval
    @run = nil
    start
  end

  def start
    return if @run
    @run = true
    @th = Thread.new do
      t = Time.now + @interval
      while run?
        to_sleep = [t - Time.now, 1].min
        if to_sleep > 0
          sleep(to_sleep) rescue nil
        else
          if run?
            @handler.call(nil) rescue nil
            t += @interval
          end
        end
      end
    end
  end

  def stop
    synchronize do
      @run = false
    end
    @th.join
  end

  private

  def run?
    synchronize do
      @run
    end
  end
end
