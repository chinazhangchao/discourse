class Enum < Hash
  # Public: Initialize an enum.
  #
  # members - Array of enum members or Hash of enum members.
  #           Array of enum members may also contain a hash of options:
  #           :start - the number of first enum member. Defaults to 1.
  #
  # Examples
  #
  #   FRUITS = Enum.new(:apple, :orange, :kiwi) # array
  #   FRUITS = Enum.new(:apple, :orange, :kiwi, start: 0) # array
  #   FRUITS = Enum.new(apple: 1, orange: 2, kiwi: 3) # hash

  def initialize(*members)
    super({})

    if members[0].is_a?(Hash)
      # hash
      # update等同于merge!，使用Hash类方法[]生成Hash（防止members[0]是Hash子类？）
      update Hash[members[0]]
    else
      # array
      # Array#extract_options! Extracts options from a set of arguments.
      # Removes and returns the last element in the array if it's a hash, otherwise returns a blank hash.
      options = members.extract_options!
      start = options.fetch(:start) { 1 }

      # a = [ 4, 5, 6 ]
      # b = [ 7, 8, 9 ]
      # [1, 2, 3].zip(a, b)   #=> [[1, 4, 7], [2, 5, 8], [3, 6, 9]]
      # [1, 2].zip(a, b)      #=> [[1, 4, 7], [2, 5, 8]]
      # a.zip([1, 2], [8])    #=> [[4, 1, 8], [5, 2, nil], [6, nil, nil]]

      # Hash[ key, value, ... ] → new_hash click to toggle source
      # Hash[ [ [key, value], ... ] ] → new_hash
      # Hash[ object ] → new_hash

      # Hash["a", 100, "b", 200]             #=> {"a"=>100, "b"=>200}
      # Hash[ [ ["a", 100], ["b", 200] ] ]   #=> {"a"=>100, "b"=>200}
      # Hash["a" => 100, "b" => 200]         #=> {"a"=>100, "b"=>200}

      update Hash[members.zip(start..members.count + start)]
    end
  end

  # Public: Access the number/value of member.
  #
  # ids_or_value - number or value of member.
  #
  # Returns value if number was provided, and number if value was provided.
  def [](id_or_value)
    # Hash key(value) → key
    # Returns the key of an occurrence of a given value. If the value is not found, returns nil.
    fetch(id_or_value) { key(id_or_value) }
  end

  # Public: Check if supplied member is valid.
  def valid?(member)
    has_key?(member)
  end

  # While clone is used to duplicate an object, including its internal state, dup typically uses the class of the descendant object to create the new instance.
  # Hash#keep_if Deletes every key-value pair from hsh for which block evaluates to false.
  # Public: Create a subset of enum, only include specified keys.
  def only(*keys)
    dup.tap do |d|
      d.keep_if { |k| keys.include?(k) }
    end
  end

  # Public: Create a subset of enum, preserve all items but specified ones.
  def except(*keys)
    dup.tap do |d|
      d.delete_if { |k| keys.include?(k) }
    end
  end
end
