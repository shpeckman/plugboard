# src/plugboard/bus.cr
class Plugboard::Bus
  getter gate : Chain(Event)

  def initialize
    @gate = Chain(Event).new
    @gate.sink = ->(event : Event) { deliver(event) }
  end

  def emit(event : T) : Bool forall T
    {% if T.union? %}
      @gate.empty? ? deliver(event) : @gate.run(event)
    {% else %}
      @gate.empty? ? topic(T).emit(event) : @gate.run(event)
    {% end %}
  end

  macro finished
      {% for type, index in ::Plugboard::EVENT_TYPES %}
        @topic_{{index}} = ::Plugboard::Topic({{type}}).new

        def topic(type : {{type}}.class) : ::Plugboard::Topic({{type}})
          @topic_{{index}}
        end
      {% end %}

      def deliver(event : ::Plugboard::Event) : Bool
        case event
        {% for type in ::Plugboard::EVENT_TYPES %}
          in {{type}} then topic({{type}}).emit(event)
        {% end %}
        end
      end
    end
end
