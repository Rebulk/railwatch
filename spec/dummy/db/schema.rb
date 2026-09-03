ActiveRecord::Schema[8.1].define(version: 1) do
  create_table "widgets", force: :cascade do |t|
    t.string "name"
    t.integer "gadget_id"
    t.timestamps
  end
  create_table "gadgets", force: :cascade do |t|
    t.string "name"
    t.timestamps
  end
  create_table "users", force: :cascade do |t|
    t.string "name"
    t.string "email"
    t.timestamps
  end
end
