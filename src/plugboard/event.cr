# src/plugboard/event.cr
module Plugboard
  EVENT_TYPES = [] of Nil

  macro events(*types)
    {% for type in types %}
      {% resolved = type.resolve %}
      {% ::Plugboard::EVENT_TYPES << resolved unless ::Plugboard::EVENT_TYPES.includes?(resolved) %}
    {% end %}
  end

  macro registered!(type)
    \{% for member in ({{type}}.union? ? {{type}}.union_types : [{{type}}]) %}
      \{% raise "plugboard: #{member} is not a registered event; add `Plugboard.events #{member}`" unless ::Plugboard::EVENT_TYPES.includes?(member) %}
    \{% end %}
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
    getter? final    : Bool
    getter? rendered : Bool

    def initialize(*, @final : Bool = false, @rendered : Bool = false)
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

  events IdleEvent, RenderEvent, FlushEvent, StoppedEvent, ErrorEvent
end
