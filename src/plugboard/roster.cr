# src/plugboard/roster.cr
struct Plugboard::Roster(T)
  def initialize
    @items = [] of T
  end

  def size : Int32
    @items.size
  end

  def empty? : Bool
    @items.empty?
  end

  def to_a : Array(T)
    @items
  end

  def add(item : T) : Nil
    items = Array(T).new(@items.size + 1)
    items.concat(@items) << item
    @items = items
  end

  def remove(item : T) : Bool
    index = @items.index(item) || return false
    items = @items.dup
    items.delete_at(index)
    @items = items
    true
  end

  def each(& : T ->) : Nil
    items = @items
    items.each { |item| yield item }
  end
end
