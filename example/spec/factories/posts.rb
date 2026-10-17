FactoryBot.define do
  factory :post do
    author factory: :user
    sequence(:title) { |n| "Post #{n}" }
    body { 'Lorem ipsum dolor sit amet.' }
    published { true }

    trait :draft do
      published { false }
    end
  end
end
