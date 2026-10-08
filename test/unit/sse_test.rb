# frozen_string_literal: true

require "test_helper"

class SseTest < Minitest::Test
  def events(*pieces)
    p = GaiaDesk::SseParser.new
    out = pieces.flat_map { |x| p.feed(x.b) }
    out + p.finish
  end

  def test_fields_comments_and_dispatch
    evs = events(": hi\nevent: stdout\ndata: {\"a\":1}\n\nevent: exit\ndata: x\ndata: y\n\n")

    assert_equal [%w[stdout {"a":1}], ["exit", "x\ny"]], evs.map(&:to_a)
  end

  def test_split_anywhere_including_crlf
    text = "event: e\r\ndata: one\r\n\r\ndata: two\r\n\r\n"

    (1...text.size).each do |cut|
      assert_equal [%w[e one], %w[message two]], events(text[0, cut], text[cut..]).map(&:to_a), "cut at #{cut}"
    end
  end

  def test_lone_cr_line_endings
    assert_equal [%w[a 1]], events("event: a\rdata: 1\r\r").map(&:to_a)
  end

  def test_unfinished_event_at_the_end_is_delivered
    assert_equal [%w[message last]], events("data: last").map(&:to_a)
  end

  def test_multibyte_split_between_reads
    text = "data: h\u00e9\u2713\n\n".b

    assert_equal ["h\u00e9\u2713"], events(text.byteslice(0, 8), text.byteslice(8, text.bytesize)).map(&:data)
  end

  def test_value_without_space_and_field_without_colon
    assert_equal [%w[message x]], events("data:x\nignored\n\n").map(&:to_a)
  end
end
