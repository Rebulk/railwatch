# frozen_string_literal: true

Rails.application.routes.draw do
  mount Railwatch::Engine, at: "/railwatch"
  get "widgets", to: "widgets#index"
  get "widgets/:id", to: "widgets#show", as: :widget
  get "boom", to: "widgets#boom"
  get "handled", to: "widgets#handled"
  get "rescued", to: "rescued#show"
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
  get "deprecated", to: "widgets#deprecated_action"
  get "redirected", to: "widgets#redirected"
  get "redirected_with_credentials", to: "widgets#redirected_with_credentials"
  get "halted", to: "widgets#halted"
  get "unpermitted", to: "widgets#unpermitted"
  get "rate_limited", to: "widgets#rate_limited"
  post "upload", to: "widgets#upload"
  get "ssr_widgets", to: "ssr_widgets#index"
end
