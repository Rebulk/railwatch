class Widget < ActiveRecord::Base
  belongs_to :gadget, optional: true
  has_one_attached :photo
end
