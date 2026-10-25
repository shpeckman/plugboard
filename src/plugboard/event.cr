# src/plugboard/event.cr
module Plugboard
  EVENT_TYPES = [] of Nil

  macro events(*types)
    {% for type in types %}
      {% resolved = type.resolve %}
      {% ::Plugboard::EVENT_TYPES << resolved unless ::Plugboard::EVENT_TYPES.includes?(resolved) %}
    {% end %}
  end

  macro finished
    alias Event = Union({{ ::Plugboard::EVENT_TYPES.splat }})
  end

  module Quiet
  end

  struct Action
    getter action : -> Nil

    def initialize(@action : -> Nil)
    end
  end

  struct IdleEvent
  end

  struct RenderEvent
  end

  struct StoppedEvent
  end

  struct FlushEvent
    getter? final : Bool

    def initialize(@final : Bool = false)
    end
  end

  abstract class Message
  end

  struct MessageEvent
    getter message : Message

    def initialize(@message : Message)
    end
  end

  class AsyncError < Message
    getter error : Exception

    def initialize(@error : Exception)
    end
  end

  class ErrorEvent
    getter error    : Exception
    getter? handled : Bool

    def initialize(@error : Exception)
      @handled = false
    end

    def handle : Nil
      @handled = true
    end
  end

  events IdleEvent, RenderEvent, FlushEvent, StoppedEvent, MessageEvent, ErrorEvent
end
