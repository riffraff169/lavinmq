require "./spec_helper"
require "./../src/lavinmq/amqp/queue"

describe LavinMQ::AMQP::StreamQueue do
  stream_queue_args = LavinMQ::AMQP::Table.new({"x-queue-type": "stream"})

  describe "Consume" do
    it "should get message with offset 2" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          q = ch.queue("pub_and_consume", args: stream_queue_args)
          10.times { |i| q.publish "m#{i}" }
          ch.prefetch 1
          msgs = Channel(AMQP::Client::DeliverMessage).new
          q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new({"x-stream-offset": 2})) do |msg|
            msgs.send msg
          end
          msg = msgs.receive
          msg.properties.headers.should eq LavinMQ::AMQP::Table.new({"x-stream-offset": 2})
          msg.body_io.to_s.should eq "m1"
        end
      end
    end

    it "should get same nr of messages as published" do
      with_amqp_server do |s|
        with_channel(s) do |ch2|
          q = ch2.queue("pub_and_consume_2", args: stream_queue_args)
          10.times { |i| q.publish "m#{i}" }
          ch2.prefetch 1
          msgs = Channel(AMQP::Client::DeliverMessage).new
          q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new({"x-stream-offset": 0})) do |msg|
            msgs.send(msg)
            msg.ack
          end
          10.times do
            msgs.receive
          end
        end
      end
    end

    it "should be able to consume multiple times" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          q = ch.queue("pub_and_consume_3", args: stream_queue_args)
          10.times { |i| q.publish "m#{i}" }
          msgs = Channel(AMQP::Client::DeliverMessage).new(20)
          ch.prefetch 1
          2.times do
            q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new({"x-stream-offset": 0})) do |msg|
              msgs.send(msg)
              msg.ack
            end
          end
          20.times do
            msgs.receive
          end
        end
      end
    end

    it "consumer gets new messages as they arrive" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          ch.prefetch 1
          args = {"x-queue-type": "stream"}
          q = ch.queue("stream-consume", args: AMQP::Client::Arguments.new(args))
          q.publish "1"
          msgs = Channel(AMQP::Client::DeliverMessage).new
          q.subscribe(no_ack: false) do |msg|
            msg.ack
            msgs.send(msg)
          end
          msgs.receive.body_io.to_s.should eq "1"
          q.publish "2"
          msgs.receive.body_io.to_s.should eq "2"
        end
      end
    end
  end

  describe "Expiration" do
    it "segments should be removed if max-length set" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          args = {"x-queue-type": "stream", "x-max-length": 1}
          q = ch.queue("stream-max-length", args: AMQP::Client::Arguments.new(args))
          data = Bytes.new(LavinMQ::Config.instance.segment_size)
          3.times { q.publish_confirm data }
          q.message_count.should eq 1
        end
      end
    end

    it "segments should be removed if max-length-bytes set" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          args = {"x-queue-type": "stream", "x-max-length-bytes": 1}
          q = ch.queue("stream-max-length-bytes", args: AMQP::Client::Arguments.new(args))
          data = Bytes.new(LavinMQ::Config.instance.segment_size)
          3.times { q.publish_confirm data }
          q.message_count.should eq 1
        end
      end
    end

    it "segments should be removed if max-age set" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          args = {"x-queue-type": "stream", "x-max-age": "1s"}
          q = ch.queue("stream-max-age", args: AMQP::Client::Arguments.new(args))
          data = Bytes.new(LavinMQ::Config.instance.segment_size)
          2.times { q.publish_confirm data }
          sleep 1.1.seconds
          q.publish_confirm data
          q.message_count.should eq 1
        end
      end
    end

    it "removes segments on publish if max-age policy is set" do
      with_amqp_server do |s|
        s.vhosts["/"].add_policy("max", "stream-max-age-policy", "queues", {"max-age" => JSON::Any.new("1s")}, 0i8)
        with_channel(s) do |ch|
          args = {"x-queue-type": "stream", "x-max-age": "1M"}
          q = ch.queue("stream-max-age-policy", args: AMQP::Client::Arguments.new(args))
          data = Bytes.new(LavinMQ::Config.instance.segment_size)
          2.times { q.publish_confirm data }
          sleep 1.1.seconds
          q.publish_confirm data
          q.message_count.should eq 1
        end
      end
    end

    it "removes segments when max-age policy is applied" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          args = {"x-queue-type": "stream", "x-max-age": "1M"}
          q = ch.queue("stream-max-age-policy", args: AMQP::Client::Arguments.new(args))
          data = Bytes.new(LavinMQ::Config.instance.segment_size)
          2.times { q.publish_confirm data }
          q.message_count.should eq 2
          sleep 1.1.seconds
          s.vhosts["/"].add_policy("max", "stream-max-age-policy", "queues", {"max-age" => JSON::Any.new("1s")}, 0i8)
          q.message_count.should eq 1
        end
      end
    end
  end

  it "doesn't support basic_get" do
    with_amqp_server do |s|
      with_channel(s) do |ch|
        q = ch.queue("stream_basic_get", args: stream_queue_args)
        q.publish_confirm "foobar"
        expect_raises(AMQP::Client::Channel::ClosedException, /NOT_IMPLEMENTED.*basic_get/) do
          ch.basic_get(q.name, no_ack: false)
        end
      end
    end
  end

  it "can requeue msgs per consumer" do
    with_amqp_server do |s|
      with_channel(s) do |ch|
        q = ch.queue("stream-requeue", args: stream_queue_args)
        q.publish_confirm "foobar"
        msgs = Channel(AMQP::Client::DeliverMessage).new
        ch.prefetch 1
        q.subscribe(no_ack: false) do |msg|
          msgs.send msg
        end
        msg1 = msgs.receive
        msg1.body_io.to_s.should eq "foobar"
        msg1.reject(requeue: true)
        msg2 = msgs.receive
        msg2.body_io.to_s.should eq "foobar"
      end
    end
  end

  it "can start consume from last segment even is queue is empty" do
    with_amqp_server do |s|
      with_channel(s) do |ch|
        q = ch.queue("empty-stream", args: stream_queue_args)
        ch.prefetch 1
        q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new({"x-stream-offset": "last"})) do |msg|
          msg.ack
        end
      end
    end
  end

  it "can be purged" do
    with_amqp_server do |s|
      with_channel(s) do |ch|
        q = ch.queue("purge-stream", args: stream_queue_args)
        data = Bytes.new(LavinMQ::Config.instance.segment_size)
        3.times { q.publish_confirm data }
        q.purge[:message_count].should eq 2 # never deletes the last segment
      end
    end
  end

  describe "Filters" do
    it "should only get message matching filter" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          ch.prefetch 1
          q = ch.queue("stream_filter_1", args: stream_queue_args)
          q.publish("msg without filter")
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "foo"})
          q.publish("msg with filter", props: AMQP::Client::Properties.new(headers: hdrs))
          q.publish("msg without filter")

          msgs = Channel(AMQP::Client::DeliverMessage).new
          q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new({"x-stream-filter": "foo"})) do |msg|
            msgs.send msg
            msg.ack
          end
          msg = msgs.receive
          msg.body_io.to_s.should eq "msg with filter"
        end
      end
    end

    it "should ignore messages with non-matching filters" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          ch.prefetch 1
          q = ch.queue("stream_filter_2", args: stream_queue_args)
          q.publish("msg without filter")
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "foo"})
          q.publish("msg with filter", props: AMQP::Client::Properties.new(headers: hdrs))
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "bar"})
          q.publish("msg with filter: bar", props: AMQP::Client::Properties.new(headers: hdrs))
          q.publish("msg without filter")

          msgs = Channel(AMQP::Client::DeliverMessage).new
          q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new({"x-stream-filter": "bar"})) do |msg|
            msgs.send msg
            msg.ack
          end
          msg = msgs.receive
          msg.body_io.to_s.should eq "msg with filter: bar"
        end
      end
    end

    it "should support multiple filters" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          ch.prefetch 1
          q = ch.queue("stream_filter_3", args: stream_queue_args)
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "foo"})
          q.publish("msg without filter")
          q.publish("msg with filter: foo", props: AMQP::Client::Properties.new(headers: hdrs))
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "xyz"})
          q.publish("msg with filter: xyz", props: AMQP::Client::Properties.new(headers: hdrs))
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "bar"})
          q.publish("msg with filter: bar", props: AMQP::Client::Properties.new(headers: hdrs))
          q.publish("msg without filter")

          msgs = Channel(AMQP::Client::DeliverMessage).new
          filters = "foo,bar"
          q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new(
            {"x-stream-filter": filters}
          )) do |msg|
            msgs.send msg
            msg.ack
          end
          msg = msgs.receive
          msg.body_io.to_s.should eq "msg with filter: foo"
          msg = msgs.receive
          msg.body_io.to_s.should eq "msg with filter: bar"
        end
      end
    end

    it "should get messages without filter when x-stream-match-unfiltered set" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          ch.prefetch 1
          q = ch.queue("stream_filter_4", args: stream_queue_args)
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "foo"})
          q.publish("msg with filter: foo", props: AMQP::Client::Properties.new(headers: hdrs))
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "bar"})
          q.publish("msg with filter: bar", props: AMQP::Client::Properties.new(headers: hdrs))
          q.publish("msg without filter")

          msgs = Channel(AMQP::Client::DeliverMessage).new
          q.subscribe(no_ack: false, args: AMQP::Client::Arguments.new(
            {
              "x-stream-filter":           "foo",
              "x-stream-match-unfiltered": true,
            }
          )) do |msg|
            msgs.send msg
            msg.ack
          end
          msg = msgs.receive
          msg.body_io.to_s.should eq "msg with filter: foo"
          msg = msgs.receive
          msg.body_io.to_s.should eq "msg without filter"
        end
      end
    end

    it "should respect offset values while filtering" do
      with_amqp_server do |s|
        with_channel(s) do |ch|
          ch.prefetch 1
          q = ch.queue("stream_filter_5", args: stream_queue_args)
          hdrs = AMQP::Client::Arguments.new({"x-stream-filter-value" => "foo"})
          q.publish("msg with filter 1", props: AMQP::Client::Properties.new(headers: hdrs))
          q.publish("msg with filter 2", props: AMQP::Client::Properties.new(headers: hdrs))
          q.publish("msg without filter")

          msgs = Channel(AMQP::Client::DeliverMessage).new
          args = AMQP::Client::Arguments.new({"x-stream-filter": "foo", "x-stream-offset": 2})
          q.subscribe(no_ack: false, args: args) do |msg|
            msgs.send msg
            msg.ack
          end
          msg = msgs.receive
          msg.body_io.to_s.should eq "msg with filter 2"
        end
      end
    end
  end
end
