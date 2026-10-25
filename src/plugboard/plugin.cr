# src/plugboard/plugin.cr
module Plugboard
  abstract class Plugin
    include Disposable

    getter ctx : Context

    def initialize(@ctx : Context)
    end

    def setup : Nil
    end

    def dispose : Nil
      @ctx.dispose
    end
  end

  macro service(declaration)
    {% type = declaration.type.resolve %}
    {% name = declaration.var %}

    class ::Plugboard::App
      @{{name}} : {{type}}?

      def {{name}} : {{type}}
        @{{name}} ||= begin
          service = root.plugin({{type}})
          service.ctx.defer { @{{name}} = nil }
          service
        end
      end

      def {{name}}? : {{type}}?
        @{{name}}
      end
    end

    ::Plugboard.scoped({{name}}, {{type}})
  end

  macro slot(declaration)
    {% type = declaration.type.resolve %}
    {% name = declaration.var %}

    class ::Plugboard::App
      @{{name}} : {{type}}?

      def {{name}} : {{type}}
        @{{name}} || raise "plugboard: no {{type}} is attached as {{name}}"
      end

      def {{name}}? : {{type}}?
        @{{name}}
      end

      def {{name}}=(value : {{type}}?) : {{type}}?
        {% if type < ::Plugboard::Plugin %}
          value.try { |item| item.ctx.defer { @{{name}} = nil if @{{name}}.same?(item) } }
        {% end %}
        @{{name}} = value
      end
    end

    ::Plugboard.scoped({{name}}, {{type}})
  end

  macro scoped(name, type)
    module ::Plugboard::Scope
      def {{name}} : {{type}}
        scope.app.{{name}}
      end

      def {{name}}? : {{type}}?
        scope.app.{{name}}?
      end
    end
  end
end
