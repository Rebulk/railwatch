# frozen_string_literal: true

module Railwatch
  module Telemetry
    # Stable keyset pagination for high-volume telemetry tables. Cursors are
    # signed and bind their sort shape, so clients cannot inject columns or use
    # a cursor from one resource/order against another.
    class CursorPage
      class InvalidCursor < ArgumentError; end

      DEFAULT_LIMIT = 50
      MAX_LIMIT = 200
      ORDERS = {
        recent: { column: :occurred_at, direction: :desc, type: :time },
        slowest: { column: :duration, direction: :desc, type: :integer }
      }.freeze

      def self.call(scope, cursor: nil, limit: nil, order: :recent, context: nil)
        new(scope, cursor: cursor, limit: limit, order: order, context: context).call
      end

      def initialize(scope, cursor:, limit:, order:, context:)
        @scope = scope
        @cursor = cursor
        parsed_limit = limit.to_i
        parsed_limit = DEFAULT_LIMIT unless parsed_limit.positive?
        @limit = [ parsed_limit, MAX_LIMIT ].min
        @order_name = order.to_sym
        @order = ORDERS.fetch(@order_name)
        @context = context.to_s
      end

      def call
        relation = apply_cursor(scope)
        relation = relation.from("#{relation.klass.quoted_table_name} INDEXED BY idx_queries_slowest") if force_slowest_index?
        rows = relation.reorder(order[:column] => order[:direction], id: order[:direction]).limit(limit + 1).to_a
        has_more = rows.length > limit
        rows = rows.first(limit)
        next_cursor = encode(rows.last) if has_more
        [ rows, { limit: limit, next_cursor: next_cursor, has_more: has_more } ]
      end

      private

      attr_reader :scope, :cursor, :limit, :order, :order_name, :context

      # SQLite's planner costs the duration-led covering index higher than
      # scanning the whole occurred_at window and sorting it, even with fresh
      # statistics, so it never picks it on its own. Forced only for the one
      # (model, order) pair the index exists for.
      def force_slowest_index?
        order_name == :slowest && scope.klass == Telemetry::Query
      end

      def apply_cursor(relation)
        values = decode
        return relation unless values

        column = relation.klass.arel_table[order[:column]]
        id = relation.klass.arel_table[:id]
        comparator = order[:direction] == :desc ? :lt : :gt
        relation.where(column.public_send(comparator, values[:value])
          .or(column.eq(values[:value]).and(id.public_send(comparator, values[:id]))))
      end

      def encode(row)
        return unless row
        value = row.public_send(order[:column])
        value = value.iso8601(6) if order[:type] == :time
        # The page size is deliberately not bound: changing it mid-scroll must
        # not hard-fail. The cursor is a stable position, not a security
        # boundary -- the scope it is applied to is already tenant-scoped here.
        verifier.generate({ v: 1, model: scope.klass.name, order: order_name,
                           context: context, value: value, id: row.id })
      end

      def decode
        return if cursor.blank?
        payload = verifier.verify(cursor.to_s).symbolize_keys
        valid_shape = payload[:v] == 1 && payload[:model] == scope.klass.name &&
          payload[:order].to_s == order_name.to_s && payload[:context] == context
        raise InvalidCursor, "invalid telemetry cursor" unless valid_shape
        value = order[:type] == :time ? Time.iso8601(payload[:value].to_s) : Integer(payload[:value].to_s, 10)
        { value: value, id: Integer(payload[:id].to_s, 10) }
      rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
        raise InvalidCursor, "invalid telemetry cursor"
      end

      def verifier
        Rails.application.message_verifier("telemetry_cursor")
      end
    end
  end
end
