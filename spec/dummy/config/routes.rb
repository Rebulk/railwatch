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
  get "page", to: "widgets#page"
  get "ssr_widgets", to: "ssr_widgets#index"
  # What Rails 8's authentication generator writes: the reset token is a
  # path segment.
  resources :passwords, param: :token, only: %i[new create edit update]
  get "invitations/:invite_code/accept", to: "passwords#accept"
  get "redirect_to_reset", to: "passwords#redirect_to_reset"
  get "reset_boom/:token", to: "passwords#boom"
  post "redirect_to_reset_preserving", to: "passwords#redirect_to_reset_preserving"
  # Same shape, different verb: POST takes a token, GET an ordinary id.
  post "resets/:token", to: "passwords#update"
  get "resets/:id", to: "widgets#show"
  get "files/*token", to: "passwords#accept"
  get "reset/prefix-:token", to: "passwords#accept"
  # A token route only on one host, and an ordinary sibling everywhere else.
  constraints(host: "auth.example.com") { get "magic/:token/edit", to: "passwords#accept" }
  get "magic/:id/edit", to: "widgets#show"
end
