# frozen_string_literal: true

Nightrail::Engine.routes.draw do
  post "beacon", to: "beacon#create"
end
