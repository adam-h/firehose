require 'spec_helper'

START_TIME = Time.now.to_i

def set_time!(time)
  Time.stub(:now) { time }
end

describe Firehose::Server::Metrics::TimeSeries do
  describe "#initialize" do
    context "invalid interval" do
      it "raises an ArgumentError if the given interval is invalid" do
        expect {
          Firehose::Server::Metrics::TimeSeries.new(seconds: nil)
        }.to raise_error(ArgumentError)

        expect {
          Firehose::Server::Metrics::TimeSeries.new(seconds: -1)
        }.to raise_error(ArgumentError)

        expect {
          Firehose::Server::Metrics::TimeSeries.new(seconds: 0)
        }.to raise_error(ArgumentError)

        expect {
          Firehose::Server::Metrics::TimeSeries.new(seconds: 0.5)
        }.to raise_error(ArgumentError)

        expect {
          Firehose::Server::Metrics::TimeSeries.new(seconds: 1)
        }.to_not raise_error

        expect {
          Firehose::Server::Metrics::TimeSeries.new(seconds: 1.5)
        }.to_not raise_error
      end
    end
  end

  describe "#current" do
    let(:metrics) { Firehose::Server::Metrics::TimeSeries.new }

    before :each do
      Time.stub(:now) { Time.at(START_TIME) }
    end

    it "always returns the same buffer for the same time" do
      expect(metrics.bucket(Time.now)).to eql(metrics.bucket(Time.now))
      expect(metrics.current).to eql(metrics.current)
    end
  end

  describe "#clear!" do
    let(:metrics) { Firehose::Server::Metrics::TimeSeries.new(seconds: 1) }

    it "resets the TimeSeries to be empty again" do
      metrics.message_published!("chan", "hello")
      expect(metrics.series).to_not eql({})
      metrics.clear!
      expect(metrics.series).to eql({})
    end
  end

  describe "#clear_old!" do
    let(:metrics) do
      Firehose::Server::Metrics::TimeSeries.new(
        seconds: seconds,
        keep_buckets: keep_buckets
      )
    end
    let(:seconds) { 5 }

    context "keep only last buckets" do
      let(:keep_buckets) { 1 }

      it "deletes all but the last bucket" do
        now = Time.now
        metrics.message_published!("chan1", "hello1")
        set_time!(now + 6)
        metrics.message_published!("chan2", "hello2")
        set_time!(now + 11)
        metrics.message_published!("chan3", "hello3")
        expect(metrics.series.size).to eql(3)
        set_time!(now + 12)
        metrics.clear_old!
        expect(metrics.series.size).to eql(1)
      end
    end

    context "keep last 2 buckets" do
      let(:keep_buckets) { 2 }

      it "deletes all but the last 2 buckets" do
        now = Time.now
        metrics.message_published!("chan1", "hello1")
        set_time!(now + 6)
        metrics.message_published!("chan2", "hello2")
        set_time!(now + 11)
        metrics.message_published!("chan3", "hello3")
        expect(metrics.series.size).to eql(3)
        set_time!(now + 12)
        metrics.clear_old!
        expect(metrics.series.size).to eql(2)
      end
    end

    context "keep last 3 buckets" do
      let(:keep_buckets) { 3 }
      let(:seconds) { 2 }

      it "deletes all but the last 3 buckets" do
        now = Time.now
        metrics.message_published!("chan1", "hello1")
        set_time!(now + 2)
        metrics.message_published!("chan2", "hello2")
        set_time!(now + 4)
        metrics.message_published!("chan3", "hello3")
        set_time!(now + 6)
        metrics.message_published!("chan4", "hello4")
        expect(metrics.series.size).to eql(4)
        set_time!(now + 8)
        metrics.clear_old!
        expect(metrics.series.size).to eql(3)
      end
    end
  end

  describe "#bucket" do
    let(:interval) { 2 }
    let(:metrics) do
      Firehose::Server::Metrics::TimeSeries.new(seconds: interval)
    end

    it "returns the same bucket for a given time within the configured seconds" do
      b0 = metrics.bucket(Time.at(0))
      b1 = metrics.bucket(Time.at(1))

      b2 = metrics.bucket(Time.at(2))
      b3 = metrics.bucket(Time.at(3))

      b4 = metrics.bucket(Time.at(4))
      b5 = metrics.bucket(Time.at(5))

      expect(b0).to eql(b1)
      expect(b1).to_not eql(b2)

      expect(b2).to eql(b3)
      expect(b3).to_not eql(b4)

      expect(b4).to eql(b5)
    end

    context "interval of 1 second" do
      let(:interval) { 1 }

      it "returns a new bucket for each second" do
        b0 = metrics.bucket(Time.at(0))
        b1 = metrics.bucket(Time.at(1))
        b2 = metrics.bucket(Time.at(2))

        expect(b0).to_not eql(b1)
        expect(b1).to_not eql(b2)
        expect(b2).to_not eql(b0)
      end
    end
  end

  describe "#series" do
    let(:metrics) do
      Firehose::Server::Metrics::TimeSeries.new(seconds: 2, gc: false)
    end

    context "without any metrics" do
      it "should be empty" do
        expect(metrics.series).to eql({})
      end
    end

    context "with one bucket having metrics" do
      let(:channel1) { "/test/channel/1" }
      let(:channel2) { "/test/channel/2" }

      before :each do
        Time.stub(:now) { Time.at(START_TIME) }
      end

      it "should return the metrics for one bucket" do
        metrics.message_published!(channel1)
        metrics.message_published!(channel2)

        buffer = Firehose::Server::Metrics::Buffer.new(metrics.bucket(Time.now), gc: false)
        buffer.message_published!(channel1)
        buffer.message_published!(channel2)

        expect(metrics.series).to be == {
          metrics.bucket(Time.now) => buffer
        }
      end
    end

    context "with multiple buckets having metrics" do
      let(:channel1) { "/test/channel/1" }
      let(:channel2) { "/test/channel/2" }

      it "shoult return the metrics for 2 buckets" do
        t1 = Time.now
        t2 = t1 + 2

        metrics.message_published!(channel1)
        metrics.message_published!(channel2)
        set_time!(t2)
        metrics.message_published!(channel2)

        bucket1 = metrics.bucket(t1)
        bucket2 = metrics.bucket(t2)

        buf1 = Firehose::Server::Metrics::Buffer.new(bucket1, gc: false)
        buf2 = Firehose::Server::Metrics::Buffer.new(bucket2, gc: false)

        buf1.message_published!(channel1)
        buf1.message_published!(channel2)
        buf2.message_published!(channel2)

        expect(metrics.series).to be == {
          bucket1 => buf1,
          bucket2 => buf2
        }
      end
    end
  end
end

describe Firehose::Server::Metrics::Buffer do
  context "new metrics instance" do
    let(:time) { 0 }
    let(:metrics) { Firehose::Server::Metrics::Buffer.new(time, gc: false) }

    describe "#==" do
      let(:buf1) { Firehose::Server::Metrics::Buffer.new(time, gc: false) }
      let(:buf2) { Firehose::Server::Metrics::Buffer.new(time, gc: false) }

      it "returns true for empty buffers" do
        expect(buf1).to be == buf2
      end

      it "returns true for two buffers with the same data" do
        buf1.message_published!("foo")
        expect(buf1).to_not be == buf2
        buf2.message_published!("foo")
        expect(buf1).to be == buf2
      end
    end

    describe "#to_hash" do
      it "returns 0 values for the metrics counters" do
        expect(metrics.to_hash).to eql({
          time: time,
          global: {
            active_channels: 0
          },
          channels: {}
        })
      end

      it "returns updated counters" do
        channel  = "/test/channel"
        channel2 = "/test/channel/2"

        3.times { metrics.new_connection! }
        metrics.connection_closed!
        metrics.message_published!(channel)
        2.times { metrics.channel_subscribed!(channel) }
        metrics.channels_subscribed_multiplexed_ws!([channel, channel2])
        metrics.channels_subscribed_multiplexed_long_polling!([channel, channel2])
        metrics.channels_subscribed_multiplexed_ws_dynamic!([{channel: "foo"}, {channel: "bar"}])

        expect(metrics.to_hash).to eql({
          time: time,
          global: {
            active_channels: 2,
            connections: 2,
            connections_opened: 3,
            connections_closed: 1,
            published: 1,
            subscribed: 2,
            subscribed_multiplexed_ws: 2,
            subscribed_multiplexed_ws_dynamic: 2,
            subscribed_multiplexed_long_polling: 2
          },
          channels: {
            channel => {
              published: 1,
              subscribed: 2,
              subscribed_multiplexed_ws: 1,
              subscribed_multiplexed_long_polling: 1
            },
            channel2 => {
              subscribed_multiplexed_ws: 1,
              subscribed_multiplexed_long_polling: 1
            }
          }
        })
      end
    end
  end
end
