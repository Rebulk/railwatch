class WidgetChannel < ActionCable::Channel::Base
  def subscribed
    stream_from "widgets"
  end

  def follow(data)
    transmit({ status: "following", id: data["id"] })
  end

  def explode(_data)
    raise "channel action failed"
  end
end
