# frozen_string_literal: true

Railwatch::Engine.routes.draw do
  post "beacon", to: "beacon#create"
end
