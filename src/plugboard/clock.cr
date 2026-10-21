# src/plugboard/clock.cr
module Plugboard::Clock
  IDLE = 1.hour

  abstract def now : Time::Instant
  abstract def budget(span : Time::Span) : Time::Span
  abstract def watch(wake : -> Nil) : Nil
  abstract def unwatch(wake : -> Nil) : Nil

  class System
    include Clock

    def now : Time::Instant
      Time.instant
    end

    def budget(span : Time::Span) : Time::Span
      span
    end

    def watch(wake : -> Nil) : Nil
    end

    def unwatch(wake : -> Nil) : Nil
    end
  end

  SYSTEM = System.new
end
