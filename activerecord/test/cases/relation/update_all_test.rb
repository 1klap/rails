# frozen_string_literal: true

require "cases/helper"
require "models/author"
require "models/category"
require "models/comment"
require "models/company"
require "models/computer"
require "models/contract"
require "models/developer"
require "models/mentor"
require "models/owner"
require "models/post"
require "models/person"
require "models/pet"
require "models/pet_treasure"
require "models/ship"
require "models/toy"
require "models/topic"
require "models/treasure"
require "models/tag"
require "models/tagging"
require "models/warehouse_thing"
require "models/cpk"

class UpdateAllTest < ActiveRecord::TestCase
  fixtures :authors, :author_addresses, :comments, :companies, :developers, :owners, :posts, :people, :pets, :toys, :tags,
    :taggings, :treasures, "warehouse-things", :cpk_orders, :cpk_order_agreements

  class TopicWithCallbacks < ActiveRecord::Base
    self.table_name = :topics
    cattr_accessor :topic_count
    before_update { |topic| topic.author_name = "David" if topic.author_name.blank? }
    after_update { |topic| topic.class.topic_count = topic.class.count }
  end

  def test_update_all_with_scope
    tag = Tag.first
    Post.tagged_with(tag.id).update_all(title: "rofl")
    posts = Post.tagged_with(tag.id).all.to_a
    assert_operator posts.length, :>, 0
    posts.each { |post| assert_equal "rofl", post.title }
  end

  def test_update_all_with_non_standard_table_name
    assert_equal 1, WarehouseThing.where(id: 1).update_all(["value = ?", 0])
    assert_equal 0, WarehouseThing.find(1).value
  end

  def test_update_all_with_blank_argument
    error = assert_raises(ArgumentError) { Comment.update_all({}) }

    assert_equal "Empty list of attributes to change", error.message
  end

  def test_update_all_with_group_by
    minimum_comments_count = 2

    Post.most_commented(minimum_comments_count).update_all(title: "ig")
    posts = Post.most_commented(minimum_comments_count).all.to_a

    assert_operator posts.length, :>, 0
    assert posts.all? { |post| post.comments.length >= minimum_comments_count }
    assert posts.all? { |post| "ig" == post.title }

    post = Post.joins(:comments).group("posts.id").having("count(comments.id) < #{minimum_comments_count}").first
    assert_not_equal "ig", post.title
  end

  def test_update_all_with_joins_and_limit
    pets = Pet.joins(:toys).where(toys: { name: "Bone" }).limit(2)

    assert_equal true, pets.exists?
    sqls = capture_sql do
      assert_equal pets.count, pets.update_all(name: "Bob")
    end

    if current_adapter?(:Mysql2Adapter, :TrilogyAdapter)
      assert_no_match %r/SELECT DISTINCT #{Regexp.escape(quote_table_name("pets.pet_id"))}/, sqls.last
    else
      assert_match %r/SELECT #{Regexp.escape(quote_table_name("pets.pet_id"))}/, sqls.last
    end
  end

  def test_update_all_with_unpermitted_relation_raises_error
    assert_deprecated("`distinct` is not supported by `update_all`", ActiveRecord.deprecator) do
      Author.distinct.update_all(name: "Bob")
    end

    assert_deprecated("`with` is not supported by `update_all`", ActiveRecord.deprecator) do
      Author.with(limited: Author.where(name: "")).update_all(name: "Bob")
    end
  end

  def test_dynamic_update_all_with_one_joined_table
    update_fragment = if current_adapter?(:TrilogyAdapter, :Mysql2Adapter)
      "toys.name = pets.name"
    else # PostgreSQLAdapter, SQLite3Adapter
      "name = pets.name"
    end

    toys = Toy.joins(:pet)
    assert_equal 3, toys.count
    assert_equal 3, toys.update_all(update_fragment)

    toys.each do |toy|
      assert_equal toy.pet.name, toy.name
    end
  end

  def test_dynamic_update_all_with_a_through_join
    pet = pets(:parrot)
    treasure = treasures(:diamond)

    PetTreasure.create(pet: pet, treasure: treasure)

    assert_operator pet.treasures.left_joins(:ship).update_all(name: "Gold"), :>, 0
    assert_equal("Gold", treasure.reload.name)
  end

  def test_dynamic_update_all_with_one_join_on_the_target_and_one_indirect_join
    update_fragment = if current_adapter?(:TrilogyAdapter, :Mysql2Adapter)
      "toys.name = owners.name"
    else # PostgreSQLAdapter, SQLite3Adapter
      "name = owners.name"
    end

    toys = Toy.joins(pet: [:owner])
    assert_equal 3, toys.count
    assert_equal 3, toys.update_all(update_fragment)

    toys.each do |toy|
      assert_equal toy.pet.owner.name, toy.name
    end
  end

  def test_dynamic_update_all_with_two_joins_on_the_target
    update_fragment = if current_adapter?(:TrilogyAdapter, :Mysql2Adapter)
      "developers.name = mentors.name"
    else # PostgreSQLAdapter, SQLite3Adapter
      "name = mentors.name"
    end

    jamis, david, poor_jamis = developers(:jamis, :david, :poor_jamis)
    jamis.update_columns(
      firm_id: companies(:first_firm).id,
      mentor_id: Mentor.create!(name: "John").id,
    )
    david.update_columns(
      firm_id: companies(:another_firm).id,
      mentor_id: Mentor.create!(name: "Goliath").id,
    )
    poor_jamis.update_columns(
      firm_id: companies(:another_firm).id,
      mentor_id: Mentor.create!(name: "Doe").id,
    )

    developers = Developer.joins(:firm, :mentor)
    assert_equal 3, developers.count
    assert_equal 3, developers.update_all(update_fragment)

    developers.each do |developer|
      assert_equal developer.name, developer.mentor.name
    end
  end

  def test_update_all_with_left_joins
    pets = Pet.left_joins(:toys).where(toys: { name: "Bone" })

    assert_equal true, pets.exists?
    assert_equal pets.count, pets.update_all(name: "Bob")
  end

  def test_update_all_with_left_outer_joins_can_reference_joined_table
    pets = Pet.left_outer_joins(:toys).where(toys: { name: ["Bone", nil] })

    assert_equal true, pets.exists?
    assert_equal pets.count, pets.update_all(name: Arel.sql("COALESCE(toys.name, 'Toyless')"))
    assert_equal "Toyless", Pet.where.missing(:toys).first.name
    assert_not_equal "Toyless", Pet.joins(:toys).first.name
  end

  def test_update_all_with_string_joins_can_reference_joined_table
    join = current_adapter?(:Mysql2Adapter, :TrilogyAdapter) ? "LEFT OUTER JOIN" : "FULL OUTER JOIN"
    pets = Pet.joins("#{join} toys ON toys.pet_id = pets.pet_id").where(toys: { name: ["Bone", nil] })

    assert_equal true, pets.exists?
    assert_equal pets.count, pets.update_all(name: Arel.sql("COALESCE(toys.name, 'Toyless')"))
    assert_equal "Toyless", Pet.where.missing(:toys).first.name
    assert_not_equal "Toyless", Pet.joins(:toys).first.name
  end

  def test_update_all_with_self_left_joins_can_reference_joined_table
    lvl2 = Comment.left_joins(parent: :parent).joins(:post).where(parent: { parent: nil }).where.not(parent: nil)

    assert_equal true, lvl2.exists?
    assert_equal lvl2.count, lvl2.update_all(body: Arel.sql("COALESCE(parent.body, posts.title)"))
  end

  def test_update_all_with_left_joins_composite_primary_key_can_reference_joined_table
    orders = Cpk::Order.left_joins(:order_agreements).where(order_agreements: { order_id: nil })

    assert_equal true, orders.exists?
    assert_equal orders.count, orders.update_all(status: Arel.sql("COALESCE(order_agreements.signature, 'orphan')"))
    assert_equal orders.count, Cpk::Order.where(status: "orphan").count
  end

  # Limitations of the implementation
  if current_adapter?(:SQLite3Adapter, :PostgreSQLAdapter)
    def test_update_all_with_left_joins_unqualified_set_reference_is_ambiguous
      orders = Cpk::Order.left_joins(:order_agreements).where(order_agreements: { order_id: nil })

      assert_raises(ActiveRecord::StatementInvalid, match: /ambiguous/) do
        orders.update_all(status: Arel.sql("CONCAT(\"status\", 'orphan')"))
      end
    end

    def test_update_all_with_left_joins_unqualified_where_reference_is_ambiguous
      orders = Cpk::Order.left_joins(:order_agreements).where(order_agreements: { order_id: nil })

      assert_raises(ActiveRecord::StatementInvalid, match: /ambiguous/) do
        orders.where(Arel.sql("\"status\" != '123'")).update_all(status: "123")
      end
    end
  end

  def test_update_all_with_includes
    pets = Pet.includes(:toys).where(toys: { name: "Bone" })

    assert_equal true, pets.exists?
    assert_equal pets.count, pets.update_all(name: "Bob")
  end

  def test_update_all_with_joins_and_limit_and_order
    comments = Comment.joins(:post).where("posts.id" => posts(:welcome).id).order("comments.id").limit(1)
    assert_equal 1, comments.count
    assert_equal 1, comments.update_all(post_id: posts(:thinking).id)
    assert_equal posts(:thinking), comments(:greetings).post
    assert_equal posts(:welcome),  comments(:more_greetings).post
  end

  def test_update_all_with_joins_and_offset_and_order
    comments = Comment.joins(:post).where("posts.id" => posts(:welcome).id).order("comments.id").offset(1)
    assert_equal 1, comments.count
    assert_equal 1, comments.update_all(post_id: posts(:thinking).id)
    assert_equal posts(:thinking), comments(:more_greetings).post
    assert_equal posts(:welcome),  comments(:greetings).post
  end

  def test_update_counters_with_joins
    assert_nil pets(:parrot).integer

    Pet.joins(:toys).where(toys: { name: "Bone" }).update_counters(integer: 1)

    assert_equal 1, pets(:parrot).reload.integer
  end

  def test_touch_all_updates_records_timestamps
    david = developers(:david)
    david_previously_updated_at = david.updated_at
    jamis = developers(:jamis)
    jamis_previously_updated_at = jamis.updated_at
    Developer.where(name: "David").touch_all

    assert_not_equal david_previously_updated_at, david.reload.updated_at
    assert_equal jamis_previously_updated_at, jamis.reload.updated_at
  end

  def test_touch_all_with_custom_timestamp
    developer = developers(:david)
    previously_created_at = developer.created_at
    previously_updated_at = developer.updated_at
    Developer.where(name: "David").touch_all(:created_at)
    developer.reload

    assert_not_equal previously_created_at, developer.created_at
    assert_not_equal previously_updated_at, developer.updated_at
  end

  def test_touch_all_with_aliased_for_update_timestamp
    assert Developer.attribute_aliases.key?("updated_at")

    developer = developers(:david)
    previously_created_at = developer.created_at
    previously_updated_at = developer.updated_at
    Developer.where(name: "David").touch_all(:updated_at)
    developer.reload

    assert_equal previously_created_at, developer.created_at
    assert_not_equal previously_updated_at, developer.updated_at
  end

  def test_touch_all_with_given_time
    developer = developers(:david)
    previously_created_at = developer.created_at
    previously_updated_at = developer.updated_at
    new_time = Time.utc(2015, 2, 16, 4, 54, 0)
    Developer.where(name: "David").touch_all(:created_at, time: new_time)
    developer.reload

    assert_not_equal previously_created_at, developer.created_at
    assert_not_equal previously_updated_at, developer.updated_at
    assert_equal new_time, developer.created_at
    assert_equal new_time, developer.updated_at
  end

  def test_update_on_relation
    topic1 = TopicWithCallbacks.create! title: "arel", author_name: nil
    topic2 = TopicWithCallbacks.create! title: "activerecord", author_name: nil
    topics = TopicWithCallbacks.where(id: [topic1.id, topic2.id])
    topics.update(title: "adequaterecord")

    assert_equal TopicWithCallbacks.count, TopicWithCallbacks.topic_count

    assert_equal "adequaterecord", topic1.reload.title
    assert_equal "adequaterecord", topic2.reload.title
    # Testing that the before_update callbacks have run
    assert_equal "David", topic1.reload.author_name
    assert_equal "David", topic2.reload.author_name
  end

  def test_update_with_ids_on_relation
    topic1 = TopicWithCallbacks.create!(title: "arel", author_name: nil)
    topic2 = TopicWithCallbacks.create!(title: "activerecord", author_name: nil)
    topics = TopicWithCallbacks.none
    topics.update(
      [topic1.id, topic2.id],
      [{ title: "adequaterecord" }, { title: "adequaterecord" }]
    )

    assert_equal TopicWithCallbacks.count, TopicWithCallbacks.topic_count

    assert_equal "adequaterecord", topic1.reload.title
    assert_equal "adequaterecord", topic2.reload.title
    # Testing that the before_update callbacks have run
    assert_equal "David", topic1.reload.author_name
    assert_equal "David", topic2.reload.author_name
  end

  def test_update_on_relation_passing_active_record_object_is_not_permitted
    topic = Topic.create!(title: "Foo", author_name: nil)
    assert_raises(ArgumentError) do
      Topic.where(id: topic.id).update(topic, title: "Bar")
    end
  end

  def test_update_bang_on_relation
    topic1 = TopicWithCallbacks.create! title: "arel", author_name: nil
    topic2 = TopicWithCallbacks.create! title: "activerecord", author_name: nil
    topic3 = TopicWithCallbacks.create! title: "ar", author_name: nil
    topics = TopicWithCallbacks.where(id: [topic1.id, topic2.id])
    topics.update!(title: "adequaterecord")

    assert_equal TopicWithCallbacks.count, TopicWithCallbacks.topic_count

    assert_equal "adequaterecord", topic1.reload.title
    assert_equal "adequaterecord", topic2.reload.title
    assert_equal "ar", topic3.reload.title
    # Testing that the before_update callbacks have run
    assert_equal "David", topic1.reload.author_name
    assert_equal "David", topic2.reload.author_name
    assert_nil topic3.reload.author_name
  end

  def test_update_all_cares_about_optimistic_locking
    david = people(:david)

    travel 5.seconds do
      now = Time.now.utc
      assert_not_equal now, david.updated_at

      people = Person.where(id: people(:michael, :david, :susan))
      expected = people.pluck(:lock_version)
      expected.map! { |version| version + 1 }
      people.update_all(updated_at: now)

      assert_equal [now] * 3, people.pluck(:updated_at)
      assert_equal expected, people.pluck(:lock_version)

      assert_raises(ActiveRecord::StaleObjectError) do
        david.touch(time: now)
      end
    end
  end

  def test_update_counters_cares_about_optimistic_locking
    david = people(:david)

    travel 5.seconds do
      now = Time.now.utc
      assert_not_equal now, david.updated_at

      people = Person.where(id: people(:michael, :david, :susan))
      expected = people.pluck(:lock_version)
      expected.map! { |version| version + 1 }
      people.update_counters(touch: { time: now })

      assert_equal [now] * 3, people.pluck(:updated_at)
      assert_equal expected, people.pluck(:lock_version)

      assert_raises(ActiveRecord::StaleObjectError) do
        david.touch(time: now)
      end
    end
  end

  def test_touch_all_cares_about_optimistic_locking
    david = people(:david)

    travel 5.seconds do
      now = Time.now.utc
      assert_not_equal now, david.updated_at

      people = Person.where(id: people(:michael, :david, :susan))
      expected = people.pluck(:lock_version)
      expected.map! { |version| version + 1 }
      people.touch_all(time: now)

      assert_equal [now] * 3, people.pluck(:updated_at)
      assert_equal expected, people.pluck(:lock_version)

      assert_raises(ActiveRecord::StaleObjectError) do
        david.touch(time: now)
      end
    end
  end

  def test_klass_level_update_all
    travel 5.seconds do
      now = Time.now.utc

      Person.all.each do |person|
        assert_not_equal now, person.updated_at
      end

      Person.update_all(updated_at: now)

      Person.all.each do |person|
        assert_equal now, person.updated_at
      end
    end
  end

  def test_klass_level_touch_all
    travel 5.seconds do
      now = Time.now.utc

      Person.all.each do |person|
        assert_not_equal now, person.updated_at
      end

      Person.touch_all(time: now)

      Person.all.each do |person|
        assert_equal now, person.updated_at
      end
    end
  end

  def test_update_all_composite_model_with_join_subquery
    agreement = cpk_order_agreements(:order_agreement_three)
    join_scope = Cpk::Order.joins(:order_agreements).where(order_agreements: { signature: agreement.signature })
    assert_equal 1, join_scope.update_all(status: "shipped")
  end

  def test_update_all_ignores_order_without_limit_from_association
    author = authors(:david)
    assert_nothing_raised do
      assert_equal author.posts_with_comments_and_categories.length, author.posts_with_comments_and_categories.update_all([ "body = ?", "bulk update!" ])
    end
  end

  def test_update_all_doesnt_ignore_order
    assert_equal authors(:david).id + 1, authors(:mary).id # make sure there is going to be a duplicate PK error
    test_update_with_order_succeeds = lambda do |order|
      Author.order(order).update_all("id = id + 1")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    if test_update_with_order_succeeds.call("id DESC")
      # test that this wasn't a fluke and using an incorrect order results in an exception
      assert_not test_update_with_order_succeeds.call("id ASC")
    else
      # test that we're failing because the current Arel's engine doesn't support UPDATE ORDER BY queries is using subselects instead
      assert_queries_match(/\AUPDATE .+ \(SELECT .* ORDER BY id DESC\)\z/i) do
        test_update_with_order_succeeds.call("id DESC")
      end
    end
  end

  def test_update_all_with_order_and_limit_updates_subset_only
    author = authors(:david)
    limited_posts = author.posts_sorted_by_id_limited
    assert_equal 1, limited_posts.size
    assert_equal 2, limited_posts.limit(2).size
    assert_equal 1, limited_posts.update_all([ "body = ?", "bulk update!" ])
    assert_equal "bulk update!", posts(:welcome).body
    assert_not_equal "bulk update!", posts(:thinking).body
  end

  def test_update_all_with_order_and_limit_and_offset_updates_subset_only
    author = authors(:david)
    limited_posts = author.posts_sorted_by_id_limited.offset(1)
    assert_equal 1, limited_posts.size
    assert_equal 2, limited_posts.limit(2).size
    assert_equal 1, limited_posts.update_all([ "body = ?", "bulk update!" ])
    assert_equal "bulk update!", posts(:thinking).body
    assert_not_equal "bulk update!", posts(:welcome).body
  end
end
