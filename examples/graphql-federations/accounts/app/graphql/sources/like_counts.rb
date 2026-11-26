# The like counts of many Authored ids, in one query.
class Sources::LikeCounts < GraphQL::Dataloader::Source
  def fetch(ids)
    counts = Like.where(authored_id: ids).group(:authored_id).count
    ids.map { |id| counts.fetch(id, 0) }
  end
end
