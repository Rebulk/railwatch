# frozen_string_literal: true

Lantern::Engine.routes.draw do
  post "beacon", to: "beacon#create"
end
