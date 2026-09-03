class RescuedController < ApplicationController
  class Boom < StandardError; end

  rescue_from Boom, with: :render_boom

  def show
    raise Boom, "rescued by the controller"
  end

  private

  def render_boom(error)
    render plain: error.message, status: :unprocessable_content
  end
end
