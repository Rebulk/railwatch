class WidgetChannel < ActionCable::Channel::Base
  def subscribed
    stream_from "widgets"
  end

  def follow(data)
    transmit({ status: "following", id: data["id"] })
  end

  def observed(data)
    Widget.where(id: data["id"]).count
    Rails.logger.info("observed widget channel action")
    ActionCable.server.broadcast("widgets:#{data['id']}:updates", { status: "observed" })
    transmit({ status: "observed", id: data["id"] })
  end

  def explode(_data)
    raise "channel action failed"
  end
end
