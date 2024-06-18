# frozen_string_literal: true

# Copyright (c) 2024 Yegor Bugayenko
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'backtrace'
require_relative '../factbase'
require_relative 'fact'
require_relative 'tee'

# Term.
#
# This is an internal class, it is not supposed to be instantiated directly.
#
# It is possible to use for testing directly, for example to make a
# term with two arguments:
#
#  require 'factbase/fact'
#  require 'factbase/term'
#  f = Factbase::Fact.new(Mutex.new, { 'foo' => [42, 256, 'Hello, world!'] })
#  t = Factbase::Term.new(:lt, [:foo, 50])
#  assert(t.evaluate(f))
#
# The design of this class may look ugly, since it has a large number of
# methods, each of which corresponds to a different type of a +Term+. A much
# better design would definitely involve many classes, one per each type
# of a term. It's not done this way because of an experimental nature of
# the project. Most probably we should keep current design intact, since it
# works well and is rather simple to extend (by adding new term types).
# Moreover, it looks like the number of possible term types is rather limited
# and currently we implement most of them.
#
# Author:: Yegor Bugayenko (yegor256@gmail.com)
# Copyright:: Copyright (c) 2024 Yegor Bugayenko
# License:: MIT
class Factbase::Term
  attr_reader :op, :operands

  require_relative 'terms/math'
  include Factbase::Term::Math

  require_relative 'terms/logical'
  include Factbase::Term::Logical

  # Ctor.
  # @param [Symbol] operator Operator
  # @param [Array] operands Operands
  def initialize(operator, operands)
    @op = operator
    @operands = operands
  end

  # Does it match the fact?
  # @param [Factbase::Fact] fact The fact
  # @param [Array<Factbase::Fact>] maps All maps available
  # @return [bool] TRUE if matches
  def evaluate(fact, maps)
    send(@op, fact, maps)
  rescue NoMethodError => e
    raise "Term '#{@op}' is not defined at #{self}: #{e.message}"
  rescue StandardError => e
    raise "#{e.message} at #{self}:\n#{Backtrace.new(e)}"
  end

  # Simplify it if possible.
  # @return [Factbase::Term] New term or itself
  def simplify
    m = "#{@op}_simplify"
    if respond_to?(m, true)
      send(m)
    else
      self
    end
  end

  # Turns it into a string.
  # @return [String] The string of it
  def to_s
    items = []
    items << @op
    items += @operands.map do |o|
      if o.is_a?(String)
        "'#{o.gsub("'", "\\\\'").gsub('"', '\\\\"')}'"
      elsif o.is_a?(Time)
        o.utc.iso8601
      else
        o.to_s
      end
    end
    "(#{items.join(' ')})"
  end

  private

  def exists(fact, _maps)
    assert_args(1)
    !by_symbol(0, fact).nil?
  end

  def absent(fact, _maps)
    assert_args(1)
    by_symbol(0, fact).nil?
  end

  def either(fact, maps)
    assert_args(2)
    v = the_values(0, fact, maps)
    return v unless v.nil?
    the_values(1, fact, maps)
  end

  def at(fact, maps)
    assert_args(2)
    i = the_values(0, fact, maps)
    raise "Too many values (#{i.size}) at first position, one expected" unless i.size == 1
    i = i[0]
    return nil if i.nil?
    v = the_values(1, fact, maps)
    return nil if v.nil?
    v[i]
  end

  def prev(fact, maps)
    assert_args(1)
    before = @prev
    v = the_values(0, fact, maps)
    @prev = v
    before
  end

  def unique(fact, _maps)
    @uniques = [] if @uniques.nil?
    assert_args(1)
    vv = by_symbol(0, fact)
    return false if vv.nil?
    vv = [vv] unless vv.is_a?(Array)
    vv.each do |v|
      return false if @uniques.include?(v)
      @uniques << v
    end
    true
  end

  def many(fact, maps)
    assert_args(1)
    v = the_values(0, fact, maps)
    !v.nil? && v.size > 1
  end

  def one(fact, maps)
    assert_args(1)
    v = the_values(0, fact, maps)
    !v.nil? && v.size == 1
  end

  def size(fact, _maps)
    assert_args(1)
    v = by_symbol(0, fact)
    return 0 if v.nil?
    return 1 unless v.is_a?(Array)
    v.size
  end

  def type(fact, _maps)
    assert_args(1)
    v = by_symbol(0, fact)
    return 'nil' if v.nil?
    v = v[0] if v.is_a?(Array) && v.size == 1
    v.class.to_s
  end

  def as(fact, maps)
    assert_args(2)
    a = @operands[0]
    raise "A symbol expected as first argument of 'as'" unless a.is_a?(Symbol)
    vv = the_values(1, fact, maps)
    vv&.each { |v| fact.send("#{a}=", v) }
    true
  end

  def nil(fact, maps)
    assert_args(1)
    the_values(0, fact, maps).nil?
  end

  def matches(fact, maps)
    assert_args(2)
    str = the_values(0, fact, maps)
    return false if str.nil?
    raise 'Exactly one string expected' unless str.size == 1
    re = the_values(1, fact, maps)
    raise 'Regexp is nil' if re.nil?
    raise 'Exactly one regexp expected' unless re.size == 1
    str[0].to_s.match?(re[0])
  end

  def defn(_fact, _maps)
    assert_args(2)
    fn = @operands[0]
    raise "A symbol expected as first argument of 'defn'" unless fn.is_a?(Symbol)
    raise "Can't use '#{fn}' name as a term" if Factbase::Term.instance_methods(true).include?(fn)
    raise "Term '#{fn}' is already defined" if Factbase::Term.private_instance_methods(false).include?(fn)
    raise "The '#{fn}' is a bad name for a term" unless fn.match?(/^[a-z_]+$/)
    e = "class Factbase::Term\nprivate\ndef #{fn}(fact, maps)\n#{@operands[1]}\nend\nend"
    # rubocop:disable Security/Eval
    eval(e)
    # rubocop:enable Security/Eval
    true
  end

  def undef(_fact, _maps)
    assert_args(1)
    fn = @operands[0]
    raise "A symbol expected as first argument of 'undef'" unless fn.is_a?(Symbol)
    if Factbase::Term.private_instance_methods(false).include?(fn)
      Factbase::Term.class_eval("undef :#{fn}", __FILE__, __LINE__ - 1) # undef :foo
    end
    true
  end

  def min(_fact, maps)
    assert_args(1)
    best(maps) { |v, b| v < b }
  end

  def max(_fact, maps)
    assert_args(1)
    best(maps) { |v, b| v > b }
  end

  def count(_fact, maps)
    maps.size
  end

  def nth(_fact, maps)
    assert_args(2)
    pos = @operands[0]
    raise "An integer expected, but #{pos} provided" unless pos.is_a?(Integer)
    k = @operands[1]
    raise "A symbol expected, but #{k} provided" unless k.is_a?(Symbol)
    maps[pos][k.to_s]
  end

  def first(_fact, maps)
    assert_args(1)
    k = @operands[0]
    raise "A symbol expected, but #{k} provided" unless k.is_a?(Symbol)
    first = maps[0]
    return nil if first.nil?
    first[k.to_s]
  end

  def sum(_fact, maps)
    k = @operands[0]
    raise "A symbol expected, but '#{k}' provided" unless k.is_a?(Symbol)
    sum = 0
    maps.each do |m|
      vv = m[k.to_s]
      next if vv.nil?
      vv = [vv] unless vv.is_a?(Array)
      vv.each do |v|
        sum += v
      end
    end
    sum
  end

  def traced(fact, maps)
    assert_args(1)
    t = @operands[0]
    raise "A term expected, but '#{t}' provided" unless t.is_a?(Factbase::Term)
    r = t.evaluate(fact, maps)
    puts "#{self} -> #{r}"
    r
  end

  def agg(fact, maps)
    assert_args(2)
    selector = @operands[0]
    raise "A term expected, but '#{selector}' provided" unless selector.is_a?(Factbase::Term)
    term = @operands[1]
    raise "A term expected, but '#{term}' provided" unless term.is_a?(Factbase::Term)
    subset = maps.select { |m| selector.evaluate(Factbase::Tee.new(Factbase::Fact.new(Mutex.new, m), fact), maps) }
    term.evaluate(nil, subset)
  end

  def assert_args(num)
    c = @operands.size
    raise "Too many (#{c}) operands for '#{@op}' (#{num} expected)" if c > num
    raise "Too few (#{c}) operands for '#{@op}' (#{num} expected)" if c < num
  end

  def by_symbol(pos, fact)
    o = @operands[pos]
    raise "A symbol expected at ##{pos}, but '#{o}' provided" unless o.is_a?(Symbol)
    k = o.to_s
    fact[k]
  end

  def the_values(pos, fact, maps)
    v = @operands[pos]
    v = v.evaluate(fact, maps) if v.is_a?(Factbase::Term)
    v = fact[v.to_s] if v.is_a?(Symbol)
    return v if v.nil?
    v = [v] unless v.is_a?(Array)
    v
  end

  def only_bool(val, pos)
    val = val[0] if val.is_a?(Array)
    return false if val.nil?
    unless val.is_a?(TrueClass) || val.is_a?(FalseClass)
      raise "Boolean expected, while #{val.class} received from #{@operands[pos]}"
    end
    val
  end

  def best(maps)
    k = @operands[0]
    raise "A symbol expected, but #{k} provided" unless k.is_a?(Symbol)
    best = nil
    maps.each do |m|
      vv = m[k.to_s]
      next if vv.nil?
      vv = [vv] unless vv.is_a?(Array)
      vv.each do |v|
        best = v if best.nil? || yield(v, best)
      end
    end
    best
  end
end
