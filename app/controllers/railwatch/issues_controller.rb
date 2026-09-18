# frozen_string_literal: true

module Railwatch
    class IssuesController < DashboardController
    BULK_LIMIT = 200

    before_action :set_issue, only: %i[show update merge_candidates]
    rescue_from Issue::InvalidMerge, with: :invalid_merge

    def index
      scope = Issue.all
      scope = scope.where(status: params[:status]) if Issue::STATUSES.include?(params[:status].to_s)
      scope = scope.where(status: "open") unless params.key?(:status)
      scope = scope.where(application_id: params[:application_id]) if params[:application_id].present?
      scope = scope.where(environment_id: params[:environment_id]) if params[:environment_id].present?
      scope = scope.where(kind: params[:kind]) if Issue::KINDS.include?(params[:kind].to_s)
      scope = scope.where(assignee_id: Viewer.user.id) if params[:mine] == "1"
      # Same "key:value free text" grammar as the other list pages: today the
      # only key is source, which is how you pull out the browser's own errors.
      parsed = FilterQuery.parse(params[:q])
      scope = scope.where(source: parsed[:fields]["source"]) if parsed[:fields]["source"].present?
      scope = scope.where("title LIKE ?", "%#{Issue.sanitize_sql_like(parsed[:text])}%") if parsed[:text].present?
      render inertia: { issues: scope.recent.limit(200).map { |i| row(i) },
                        filters: params.permit(:status, :application_id, :environment_id, :kind, :mine, :q).to_h,
                        counts: Issue.all.group(:status).count,
                        kindCounts: Issue.all.open.group(:kind).count,
                        members: User.default.then { |u| [ { id: u.id, name: u.name } ] } }
    end

    def show
      env = @issue.environment
      return render_detection_issue(env) unless @issue.kind == "exception"

      from = 30.days.ago
      occurrences = env.with_telemetry do
        Telemetry::Exception.where(group_hash: @issue.group_hash).between(from, Time.current).recent.limit(50)
          .map { |e| { id: e.id, message: e.message.first(300), handled: e.handled, occurred_at: e.occurred_at, execution_id: e.execution_id, execution_source: e.execution_source, execution_preview: e.execution_preview, user_ref: e.user_ref, tenant: e.app_tenant, deploy: e.deploy, server: e.server } }
      end
      latest = env.with_telemetry { Telemetry::Exception.where(group_hash: @issue.group_hash).recent.first }
      browser_breadcrumbs = browser_breadcrumbs_for(latest)
      breadcrumbs = latest&.execution_id ? env.with_telemetry { breadcrumbs_for(latest) } : []
      daily_counts = env.with_telemetry { Telemetry::Exception.where(group_hash: @issue.group_hash).between(from, Time.current).group(Arel.sql("date(occurred_at)")).count }.transform_keys(&:to_s)
      daily = (from.to_date..Date.current).map { |d| { day: d.to_s, count: daily_counts[d.to_s].to_i } }
      by_deploy = env.with_telemetry { Telemetry::Exception.where(group_hash: @issue.group_hash).between(from, Time.current).group(:deploy).count }
      by_tenant = env.with_telemetry { Telemetry::Exception.where(group_hash: @issue.group_hash).between(from, Time.current).where.not(app_tenant: nil).group(:app_tenant).count }
      attachments = env.with_telemetry { attachments_for_issue }
      # What a split by message would produce, and what the fingerprint that
      # grouped these occurrences was -- both drive the Grouping panel.
      messages = env.with_telemetry { Telemetry::Exception.where(group_hash: @issue.group_hash).recent.limit(Issue::SPLIT_SAMPLE).pluck(:message) }.tally
      render inertia: {
        issue: row(@issue).merge(first_seen_at: @issue.first_seen_at, resolved_at: @issue.resolved_at, resolved_in_deploy: @issue.resolved_in_deploy, regressed_at: @issue.regressed_at, sample: @issue.sample),
        detection: nil,
        latest: latest && { id: latest.id, class_name: latest.class_name, message: latest.message, handled: latest.handled, severity: latest.severity, source: latest.source, file: latest.file, line: latest.line, frames: latest.frames, cause: latest.cause, locals: latest.locals, context: context_without_breadcrumbs(latest), ruby_version: latest.ruby_version, rails_version: latest.rails_version, execution_id: latest.execution_id, execution_source: latest.execution_source, execution_preview: latest.execution_preview, deploy: latest.deploy },
        breadcrumbs: breadcrumbs, browser_breadcrumbs: browser_breadcrumbs,
        fingerprint: (latest&.fingerprint).presence || Array(@issue.sample["fingerprint"]),
        fingerprint_source: latest&.fingerprint_source || @issue.sample["fingerprint_source"],
        distinct_messages: messages.size,
        top_messages: messages.sort_by { |_, n| -n }.first(5).map { |message, n| { message: message.to_s.first(200), count: n } },
        occurrences: occurrences, daily: daily, by_deploy: by_deploy, by_tenant: by_tenant, attachments: attachments,
        comments: @issue.comments.order(:created_at).map { |c| { id: c.id, body: c.body, user: c.user&.name || c.author_name || "Linear", source: c.source, created_at: c.created_at } },
        activities: @issue.activities.order(:created_at).map { |a| activity_row(a) },
        members: User.default.then { |u| [ { id: u.id, name: u.name } ] },
        deploys: env.deploys.recent.limit(20).map { |d| { deploy: d.deploy, ref: d.short_ref, at: d.deployed_at } },
        related_issues: related_issues,
        merged_into: @issue.merged_into && { id: @issue.merged_into.id, key: @issue.merged_into.key, title: @issue.merged_into.title },
        merged_issues: @issue.merged_issues.map { |i| { id: i.id, key: i.key, title: i.title } },
        alerts: @issue.alerts.order(created_at: :desc).map { |a| alert_row(a) }
      }
    end

    def merge_candidates
      query = params[:q].to_s.strip.first(200)
      scope = @issue.environment.issues.open.where.not(id: @issue.id)
      if query.present?
        pattern = "%#{Issue.sanitize_sql_like(query)}%"
        key_match = query.upcase.match(/\A#{Regexp.escape(@issue.application.issue_prefix)}-(\d+)\z/)
        scope = if key_match
          scope.where("title LIKE :pattern OR number = :number", pattern: pattern, number: key_match[1].to_i)
        else
          scope.where("title LIKE ?", pattern)
        end
      end

      render json: { issues: scope.order(last_seen_at: :desc, id: :desc).limit(20)
        .map { |issue| { id: issue.id, key: issue.key, title: issue.title } } }
    end

    def update
      notice = "Issue updated"
      case params[:action_name]
      when "resolve" then @issue.resolve!(deploy: params[:deploy].presence || @issue.environment.deploys.recent.first&.deploy)
      when "ignore" then @issue.ignore!
      when "reopen" then @issue.reopen!
      when "assign" then @issue.update!(assignee: assignee_from(params[:assignee_id]))
      when "assign_me" then @issue.update!(assignee_id: Viewer.user.id)
      when "priority" then @issue.update!(priority: params[:priority])
      when "merge" then @issue.merge_into!(@issue.environment.issues.open.find(params[:target_id]))
      when "unmerge" then @issue.unmerge!
      when "split" then notice = split_notice(@issue.split!(by: params[:by].to_s))
      else @issue.update!(params.permit(:title))
      end
      redirect_to issue_path(@issue), notice: notice
    end

    def bulk
      ids = Array(params[:ids]).first(BULK_LIMIT)
      scope = Issue.all.where(id: ids)
      if params[:action_name] == "merge"
        bulk_merge(scope)
      else
        scope.find_each do |issue|
          case params[:action_name]
          when "resolve" then issue.resolve!(deploy: issue.environment.deploys.recent.first&.deploy)
          when "ignore" then issue.ignore!
          when "priority" then issue.update!(priority: params[:value])
          end
        end
      end
      redirect_back fallback_location: issues_path, notice: "#{ids.size} issue(s) updated"
    end

    private

    # A stale selection can contain issues that have already been merged since
    # the list rendered. Ignore those sources, choose an open target, and wrap
    # the whole operation so a concurrent state change cannot partially fold a
    # bulk selection before the model rejects it.
    def bulk_merge(scope)
      issues = scope.order(:first_seen_at, :id).to_a
      target = issues.find(&:open?)
      return unless target

      Issue.transaction do
        issues.each do |issue|
          next if issue.id == target.id || issue.environment_id != target.environment_id || issue.merged?

          issue.merge_into!(target)
        end
      end
    end

    def invalid_merge(error)
      redirect_back fallback_location: (@issue ? issue_path(@issue) : issues_path), alert: error.message
    end

    def render_detection_issue(env)
      render inertia: {
        issue: row(@issue).merge(first_seen_at: @issue.first_seen_at, resolved_at: @issue.resolved_at,
          resolved_in_deploy: @issue.resolved_in_deploy, regressed_at: @issue.regressed_at, sample: @issue.sample),
        detection: IssueDetectionPresenter.new(@issue).as_json,
        latest: nil, breadcrumbs: [], browser_breadcrumbs: [], fingerprint: [], fingerprint_source: nil,
        distinct_messages: 0, top_messages: [], occurrences: [], daily: [], by_deploy: {}, by_tenant: {}, attachments: [],
        comments: @issue.comments.order(:created_at).map { |c| { id: c.id, body: c.body, user: c.user.name, created_at: c.created_at } },
        activities: @issue.activities.order(:created_at).map { |a| activity_row(a) },
        members: User.default.then { |u| [ { id: u.id, name: u.name } ] },
        deploys: env.deploys.recent.limit(20).map { |d| { deploy: d.deploy, ref: d.short_ref, at: d.deployed_at } },
        related_issues: related_issues,
        merged_into: @issue.merged_into && { id: @issue.merged_into.id, key: @issue.merged_into.key, title: @issue.merged_into.title },
        merged_issues: @issue.merged_issues.map { |i| { id: i.id, key: i.key, title: i.title } },
        alerts: @issue.alerts.order(created_at: :desc).map { |a| alert_row(a) }
      }
    end

    # Sentry-style breadcrumbs: everything the execution did before it raised
    # (queries, cache, outgoing calls, logs, jobs), newest last, capped at 30.
    def breadcrumbs_for(exception)
      exe = Telemetry::Execution.find_by(execution_id: exception.execution_id) or return []
      ExecutionPresenter.new(exe, @issue.environment).timeline_entries
        .select { |e| e[:offset] <= ((exception.occurred_at - exe.occurred_at) * 1000.0) + 1 }
        .reject { |e| e[:type] == "exception" && e[:id] == exception.id }
        .last(30)
    end

    # A browser exception's execution is the beacon POST that carried it, whose
    # timeline says nothing about the crash. What it has instead is the trail
    # the browser client recorded -- console errors, clicks, navigations --
    # which the gem stores in the exception's context.
    def browser_breadcrumbs_for(exception)
      trail = browser_context(exception)["breadcrumbs"]
      return [] unless trail.is_a?(Array)
      trail.filter_map { |crumb| crumb.slice("at", "kind", "text") if crumb.is_a?(Hash) }
    end

    # The same context with the trail taken back out, since the page renders it
    # as a breadcrumb list rather than as raw JSON in the context panel.
    def context_without_breadcrumbs(exception)
      context = parsed_context(exception)
      return exception.context unless context["browser"].is_a?(Hash) && context["browser"].key?("breadcrumbs")
      context.merge("browser" => context["browser"].except("breadcrumbs")).to_json
    end

    def browser_context(exception)
      context = parsed_context(exception)
      context["browser"].is_a?(Hash) ? context["browser"] : {}
    end

    # Exception context is a JSON string the gem built; anything else in that
    # column is an older or garbled record, and reads as empty rather than 500.
    def parsed_context(exception)
      parsed = JSON.parse(exception&.context.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # Files the app attached while raising this exception, from any execution.
    # `data` is left out of the select: it is the whole gzipped file and the
    # page only links to the download.
    def attachments_for_issue
      Telemetry::Attachment.where(exception_group_hash: @issue.group_hash).recent.limit(20)
        .select(:id, :name, :content_type, :bytes, :truncated, :occurred_at, :execution_id, :execution_preview)
        .map { |a| { id: a.id, name: a.name, content_type: a.content_type, bytes: a.bytes, truncated: a.truncated,
                     viewable: a.viewable?, occurred_at: a.occurred_at, execution_id: a.execution_id, execution_preview: a.execution_preview } }
    end

    # split! no-ops when there is nothing to split apart (the button is hidden
    # then, but a stale page can still ask), so say which one happened.
    def split_notice(created)
      created.empty? ? "Nothing to split \u2014 every recent occurrence is already in its own issue" : "Split into #{created.size} issue(s)"
    end

    def set_issue
      @issue = Issue.all.find(params[:id])
    end

    # Only a member of the current account can be assigned; nil clears.
    def assignee_from(id)
      id.present? ? User.find(id) : nil
    end

    # Same exception class seen in other environments of the same application:
    # issue titles are stored as "ClassName: message", so we match on the
    # "ClassName:" prefix.
    def related_issues
      class_name = @issue.title.to_s.split(":", 2).first
      return [] if class_name.blank?
      Issue.all.where.not(id: @issue.id)
        .where("title LIKE ?", "#{Issue.sanitize_sql_like(class_name)}:%").limit(20)
        .map { |i| { id: i.id, key: i.key, title: i.title, status: i.status, environment: { id: i.environment.id, name: i.environment.name } } }
    end

    def row(i)
      { id: i.id, key: i.key, title: i.title, kind: i.kind, status: i.status, priority: i.priority, culprit: i.culprit, occurrences: i.occurrences,
        affected_users: i.affected_users, first_seen_at: i.first_seen_at, last_seen_at: i.last_seen_at, assignee: i.assignee && { id: i.assignee.id, name: i.assignee.name },
        fingerprint_source: i.sample["fingerprint_source"], source: i.source,
        application: { id: i.application.id, name: i.application.name }, environment: { id: i.environment.id, name: i.environment.name } }
    end

    def activity_row(a)
      { id: a.id, kind: a.kind, data: a.data, user: a.user && { id: a.user.id, name: a.user.name }, created_at: a.created_at }
    end

    def alert_row(a)
      { id: a.id, event: a.event, status: a.status, sent_at: a.sent_at, error: a.error,
        integration: { kind: a.integration.kind, name: a.integration.name } }
    end
    end
end
