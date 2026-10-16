# src/plugboard/disposable.cr
module Plugboard::Disposable
  property slot : Int32 = -1

  abstract def dispose : Nil
end

require "./disposable/*"
