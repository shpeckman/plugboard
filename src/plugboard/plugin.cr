# src/plugboard/plugin.cr
module Plugboard
  abstract class Plugin
    include Disposable

    getter ctx : Context

    def initialize(@ctx : Context)
    end

    def setup : Nil
    end

    def buffer : Bytewire
      @ctx.buffer
    end

    def dispose : Nil
      @ctx.dispose
    end
  end

  macro service(declaration)
    {% type = declaration.type.resolve %}

    class ::Plugboard::App
      @{{declaration.var}} : {{type}}?

      def {{declaration.var}} : {{type}}
        @{{declaration.var}} ||= begin
          service = root.plugin({{type}})
          service.ctx.effect { -> { @{{declaration.var}} = nil } }
          service
        end
      end

      def {{declaration.var}}? : {{type}}?
        @{{declaration.var}}
      end
    end

    class ::Plugboard::Context
      def {{declaration.var}} : {{type}}
        @app.{{declaration.var}}
      end
    end
  end
end
