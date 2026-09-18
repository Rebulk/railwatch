# frozen_string_literal: true

require "spec_helper"

# Whatever a host's dashboard_user resolver returns as `id` is stored and
# handed back. Apps number their users in whatever way they already chose --
# integers, UUIDs, ULIDs, an email -- and the engine has no user table to
# check any of it against, so it keeps an opaque handle rather than assuming
# a shape. This is the spec that would have caught the original integer
# columns, on which a UUID app could not write a comment at all.
RSpec.describe "host user ids", type: :request do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
    Railwatch.config.dashboard_user = nil
    Railwatch::Viewer.user = nil
  end

  def signed_in_as(id, name: "Ada")
    Railwatch.config.dashboard_user = ->(_request) { { id: id, name: name } }
    Railwatch::Viewer.user = Railwatch.config.resolve_dashboard_user(nil)
  end

  UUID = "018f3a2b-9c4d-7e1f-8a2b-3c4d5e6f7a8b"

  [
    [ "a UUID", UUID ],
    [ "an integer", 7 ],
    [ "an id past the signed integer range", 9_223_372_036_854_775_808 ],
    [ "an email", "ada@example.com" ]
  ].each do |shape, id|
    it "stores and resolves #{shape}" do
      signed_in_as(id)
      view = Railwatch::SavedView.create!(name: "Mine", page: "requests", environment_id: 1, user: Railwatch::Viewer.user)

      expect(view.reload.viewer_id).to eq(id.to_s)
      expect(view.user.id.to_s).to eq(id.to_s)
      expect(view.user.name).to eq("Ada")
    end
  end

  it "keeps a view private to the person who made it, whatever their id looks like" do
    signed_in_as(UUID)
    # shared defaults to true, so a private view says so explicitly.
    mine = Railwatch::SavedView.create!(name: "Mine", page: "requests", shared: false,
                                        environment_id: 1, user: Railwatch::Viewer.user)
    shared = Railwatch::SavedView.create!(name: "Shared", page: "requests", shared: true,
                                          environment_id: 1, user: Railwatch::Viewer.user)

    signed_in_as("018f3a2b-0000-0000-0000-000000000000", name: "Bob")
    visible = Railwatch::SavedView.visible_to(Railwatch::Viewer.user)

    expect(visible).to include(shared)
    expect(visible).not_to include(mine)
  end

  # A row written before the widening migration holds an integer; the same
  # person signing in afterwards must still own it.
  it "matches a row stored as a number against a resolver that returns one" do
    signed_in_as(7)
    view = Railwatch::SavedView.create!(name: "Mine", page: "requests", environment_id: 1, user: Railwatch::Viewer.user)
    view.update_column(:viewer_id, 7)

    expect(view.reload.user.id.to_s).to eq("7")
    expect(Railwatch::SavedView.visible_to(Railwatch::Viewer.user)).to include(view)
  end

  it "names the resolved person as the account's member, not the anonymous operator" do
    signed_in_as(UUID, name: "Ada")

    expect(Railwatch::Embedded::Account.members.map(&:name)).to eq([ "Ada" ])
  end

  it "falls back to the anonymous operator when the host names nobody" do
    Railwatch::Viewer.user = Railwatch.config.resolve_dashboard_user(nil)

    expect(Railwatch::Viewer.user.id).to eq(Railwatch::User::ID)
    expect(Railwatch::Embedded::Account.members.map(&:name)).to eq([ "Operator" ])
  end
end
