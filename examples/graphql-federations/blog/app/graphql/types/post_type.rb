class Types::PostType < Types::BaseObject
  # Post.readingTime has no directive: Lighthouse resolves it with this method.
  def reading_time
    Types::ReadingTimeType.of(object)
  end
end
