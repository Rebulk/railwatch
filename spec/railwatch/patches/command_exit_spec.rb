# frozen_string_literal: true

require "spec_helper"
require "open3"
require "socket"
require "tmpdir"

# What a cloud-only rake task costs on the way out when the receiver is wedged,
# and that it still reports the thing worth reporting when it is not.
#
# The command patches used to call `Railwatch.flush` when a task finished, on
# the application's own thread and with no bound. The engine's at_exit already
# calls Reporter#shutdown, which joins the reporter thread for
# shutdown_timeout -- so the flush delivered the same records a second way and
# was the only unbounded part of the exit. Against a receiver that accepts
# connections and never answers it cost a full timeout ladder per process,
# measured at ~8s, which is enough to lose a deploy on an entrypoint that boots
# Rails repeatedly.
#
# These are process-level on purpose. In-process examples would pass whether or
# not the flush is there, because the cost lives in a socket read and the bound
# lives in an at_exit join.
RSpec.describe "a cloud-only command process exiting" do
  # Accepts, then says nothing. A refused connection fails immediately and
  # would not exercise the timeout this guards at all.
  def with_hung_receiver
    server = TCPServer.new("127.0.0.1", 0)
    # Held, not dropped. An accepted socket that goes out of scope can be
    # collected, and collecting it closes the descriptor -- the client would
    # then read EOF straight away instead of waiting, and this would pass
    # without ever having exercised a hung receiver.
    accepted = []
    accepter = Thread.new do
      loop { accepted << server.accept }
    rescue StandardError
      nil
    end
    yield server.addr[1]
  ensure
    accepter&.kill
    accepted&.each { |socket| socket.close rescue nil }
    server&.close
  end

  def run_fixture(port)
    Dir.mktmpdir("railwatch-rake-exit") do |root|
      FileUtils.mkdir_p("#{root}/config")
      File.write("#{root}/config/database.yml", "test:\n  adapter: sqlite3\n  database: ':memory:'\n")
      output, status = Open3.capture2e(
        { "RAILS_ENV" => "test", "RAKE_EXIT_ROOT" => root, "RAKE_EXIT_PORT" => port.to_s },
        Gem.ruby, File.expand_path("../../fixtures/rake_exit.rb", __dir__))
      [ output, status ]
    end
  end

  def timing(output, key)
    output[/#{key}=([0-9.]+)/, 1]&.to_f
  end

  it "does not pay for the wedged receiver twice, and exits within the shutdown bound" do
    output, status = with_hung_receiver { |port| run_fixture(port) }

    expect(status.success?).to be(true), output
    task = timing(output, "TASK_RETURNED_AFTER")
    exiting = timing(output, "PROCESS_EXITING_AFTER")
    expect(task).not_to be_nil, output
    expect(exiting).not_to be_nil, output

    # The task itself must not wait on the network at all. Generous against a
    # loaded CI box, and still far below the ~6.6s a single unbounded flush
    # cost (3s read timeout, one retry) let alone the ~12s it cost when it
    # queued behind a delivery the reporter thread was already stuck in.
    expect(task).to be < 3.0

    # And the whole process still leaves inside the shutdown bound, which is
    # what makes an entrypoint that boots Rails repeatedly survivable.
    bound = Railwatch.config.shutdown_timeout + 3.0
    expect(exiting).to be < bound

    # Leaving inside the bound means leaving records behind -- and this is the
    # process that most needs to say so. A rake task gets one bounded shutdown
    # and no second chance, so a cron job whose exception never reached the
    # platform would otherwise look exactly like one that had nothing to
    # report. The fixture sets neither RAILWATCH_DEBUG nor warn_on_data_loss,
    # so this is the default install talking.
    expect(output).to include("[railwatch]")
    expect(output).to include("unsent records")
  end
end
