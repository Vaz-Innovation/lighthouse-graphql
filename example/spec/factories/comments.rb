FactoryBot.define do
  factory :comment do
    post
    author factory: :user
    body { 'Nice post!' }
  end
end
