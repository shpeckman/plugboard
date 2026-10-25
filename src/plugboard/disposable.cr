# src/plugboard/disposable.cr
module Plugboard::Disposable
  property held_index : Int32 = -1

  abstract def dispose : Nil
end

require "./disposable/*"
