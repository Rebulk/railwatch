class Widget < ActiveRecord::Base
  belongs_to :gadget, optional: true
end
