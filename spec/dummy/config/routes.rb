# frozen_string_literal: true

Rails.application.routes.draw do
  mount Lantern::Engine, at: "/lantern"
  get "widgets", to: "widgets#index"
  get "widgets/:id", to: "widgets#show", as: :widget
  get "boom", to: "widgets#boom"
  get "handled", to: "widgets#handled"
  get "cached", to: "widgets#cached"
  get "outbound", to: "widgets#outbound"
  get "mail", to: "widgets#mail"
  get "enqueue", to: "widgets#enqueue"
  get "inertia", to: "widgets#inertia"
  get "sampled", to: "widgets#sampled"
  get "ignored", to: "widgets#ignored"
  get "many", to: "widgets#many"
  get "storage", to: "widgets#storage"
  get "override_sample", to: "widgets#override_sample"
  post "upload", to: "widgets#upload"
  get "ssr_widgets", to: "ssr_widgets#index"
end
