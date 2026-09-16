# frozen_string_literal: true

class AlertRule < RailwatchRecord
  TITLE_PATTERN_MAX_LENGTH = 256
  TITLE_PATTERN_TIMEOUT = 0.01
  EVENTS = %w[new_issue regressed_issue resolved_issue ignored_issue assigned_issue threshold anomaly silent_host quota crash_free_drop].freeze

  # A deploy that breaks one page opens dozens of issues in a minute, and
  # each one used to be its own Slack message. These two events are the ones
  # that arrive in bursts.
  BURST_EVENTS = %w[new_issue regressed_issue].freeze
  BURST_WINDOW = 60.seconds
  # Deliver this many individually, then fold the rest of the window into one
  # summary message.
  BURST_LIMIT = 5

  def application = ::Application.current
  def integration = nil
  has_many :alerts, dependent: :destroy

  validates :event, inclusion: { in: EVENTS }
  validate :valid_title_pattern

  # De-duplicate: one alert per issue per event per 30 minutes.
  def fire!(event:, issue: nil, payload: {})
    # Serialize the duplicate/burst decision per rule. The alert is born in
    # its final outbox state, so its after-commit hook can never enqueue a row
    # that is about to become collapsed.
    with_lock do
      return if issue && alerts.where(issue: issue, event: event).where("created_at > ?", 30.minutes.ago).exists?

      status = bursting?(event, issue) ? "collapsed" : "pending"
      alerts.create!(event: event, issue: issue, payload: payload, status: status)
    end
  end

  # Optional narrowing of what this rule notifies about, stored in `filters`:
  # environment_ids, kinds, min_priority, title_pattern. An absent or empty
  # filter matches everything; an issue-less alert (quota, silent_host) is
  # only narrowed by environment, via payload[:environment_id].
  def matches?(issue:, payload: {})
    return false unless environment_matches?(issue, payload)
    return true unless issue
    kind_matches?(issue) && priority_matches?(issue) && title_matches?(issue)
  end

  private

  def valid_title_pattern
    pattern = filters["title_pattern"].to_s
    return if pattern.blank?

    if pattern.length > TITLE_PATTERN_MAX_LENGTH
      errors.add(:filters, "title pattern is too long (maximum is #{TITLE_PATTERN_MAX_LENGTH} characters)")
      return
    end
    return unless regular_expression_pattern?(pattern)

    compile_title_pattern(pattern)
  rescue RegexpError => e
    errors.add(:filters, "title pattern is not a valid regular expression: #{e.message}")
  end

  # True once this rule has already fired BURST_LIMIT issue alerts inside the
  # window. Only alerts that carry an issue are counted, so summary rows can
  # never inflate the next window's tally.
  def bursting?(event, issue)
    return false unless BURST_EVENTS.include?(event) && issue
    alerts.where(event: event, created_at: BURST_WINDOW.ago..).where.not(issue_id: nil).count >= BURST_LIMIT
  end

  def environment_matches?(issue, payload)
    ids = Array(filters["environment_ids"]).compact_blank.map(&:to_i)
    return true if ids.empty?
    ids.include?((issue&.environment_id || payload[:environment_id] || payload["environment_id"]).to_i)
  end

  def kind_matches?(issue)
    kinds = Array(filters["kinds"]).compact_blank
    kinds.empty? || kinds.include?(issue.kind)
  end

  def priority_matches?(issue)
    minimum = filters["min_priority"]
    return true if minimum.blank? || Issue::PRIORITIES.exclude?(minimum)
    Issue::PRIORITIES.index(issue.priority) >= Issue::PRIORITIES.index(minimum)
  end

  # A pattern wrapped in slashes is a regular expression, anything else is a
  # case-insensitive substring.
  def title_matches?(issue)
    pattern = filters["title_pattern"].to_s
    return true if pattern.blank?
    if regular_expression_pattern?(pattern)
      begin
        return issue.title.match?(compile_title_pattern(pattern))
      rescue Regexp::TimeoutError
        # A pattern that backtracks past its budget matches nothing rather
        # than stalling every alert behind it.
        Rails.logger.warn("alert rule title pattern timed out alert_rule_id=#{id}")
        return false
      rescue RegexpError
        # An unparsable regexp degrades to a substring match on its source, so
        # a rule saved before this was validated does not silently go dark.
        pattern = pattern[1..-2]
      end
    end
    issue.title.downcase.include?(pattern.downcase)
  end

  def regular_expression_pattern?(pattern)
    pattern.start_with?("/") && pattern.end_with?("/") && pattern.length > 2
  end

  def compile_title_pattern(pattern)
    Regexp.new(pattern[1..-2], Regexp::IGNORECASE, timeout: TITLE_PATTERN_TIMEOUT)
  end
end
