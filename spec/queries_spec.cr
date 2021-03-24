require "uuid"
require "./spec_helper"

describe RethinkORM::Queries do
  it "#all" do
    BasicModel.clear

    num_documents = 5
    num_documents.times { BasicModel.create(name: "Psyduck") }

    models = BasicModel.all.to_a
    models.size.should eq num_documents
    models.all?(&.name.==("Psyduck")).should be_true
  end

  it "#find!" do
    model = BasicModel.create!(name: Faker::Name.name)
    found_model = BasicModel.find!(model.id.as(String))

    found_model.id.should eq model.id
  end

  it "#exists?" do
    model = BasicModel.create!(name: Faker::Name.name)
    BasicModel.exists?(model.id.as(String)).should be_true
  end

  describe "#find_all" do
    it "returns documents matching passed ids" do
      correct_documents = Array.new(size: 5) do |_|
        BasicModel.create!(name: Faker::Name.name, age: 10)
      end
      ids = (correct_documents.compact_map &.id).sort
      found_ids = (BasicModel.find_all(ids).to_a.compact_map &.id).sort
      found_ids.should eq ids
    end

    it "searches on index" do
      correct_documents = Array.new(size: 5) do |_|
        Car.create!(brand: Faker::Name.name, vin: UUID.random.to_s)
      end
      vin = (correct_documents.compact_map &.vin).sort.first
      found_vins = (Car.find_all([vin], index: :vin).to_a.compact_map &.vin).sort

      found_vins.size.should eq 1
      found_vins.first.should eq vin
    end

    it "ignores missing ids" do
      num_documents = 5
      correct_documents = Array.new(size: num_documents) do |_|
        BasicModel.create!(name: Faker::Name.name, age: 10)
      end

      ids = (correct_documents.compact_map &.id).sort
      fake_ids = Array.new(size: 5) { |_| Faker::Name.name }
      all_ids = ids + fake_ids

      found_ids = (BasicModel.find_all(all_ids).to_a.compact_map &.id).sort
      found_ids.size.should eq num_documents
      found_ids.should eq ids
    end
  end

  describe "#count" do
    it "tallys the documents in a table" do
      BasicModel.clear

      num_correct = 5
      correct_documents = Array.new(size: num_correct) do |_|
        BasicModel.create!(name: Faker::Name.name, age: 10)
      end

      count = BasicModel.count
      count.should be_a(Int32)
      count.should eq num_correct
      correct_documents.each &.destroy
    end

    it "tallys the documents with specific attributes" do
      num_correct = 3
      num_incorrect = 4
      correct_name = Faker::Name.name
      incorrect_name = Faker::Name.name

      correct_documents = Array.new(size: num_correct) do |_|
        BasicModel.create!(name: correct_name, age: 10)
      end

      incorrect_documents = Array.new(size: num_incorrect) do |_|
        BasicModel.create!(name: incorrect_name, age: 10)
      end

      total = BasicModel.count
      correct_count = BasicModel.count(name: correct_name)
      incorrect_count = BasicModel.count(name: incorrect_name)

      correct_count.should eq num_correct
      incorrect_count.should eq num_incorrect
      total.should eq (num_correct + num_incorrect)

      correct_documents.each &.destroy
      incorrect_documents.each &.destroy
    end

    it "tallys the documents that satisfy a predicate" do
      name = Faker::Name.name
      num_documents = 5
      documents = Array.new(size: num_documents) do |idx|
        BasicModel.create!(name: name, age: idx)
      end

      total = BasicModel.count(name: name)
      lt3 = BasicModel.count(name: name) do |doc|
        doc["age"] < 3
      end

      total.should eq num_documents
      lt3.should eq 3

      documents.each &.destroy
    end
  end

  it "#raw_query" do
    tree1 = Tree.new
    tree2 = Tree.new

    roots = 3.times.to_a.compact_map do
      Root.create!(length: (rand * 10).to_f32).id
    end

    # Check all roots created
    roots.size.should eq 3

    tree1.roots = roots[0..1]
    tree2.roots = roots[1..2]

    tree1.save
    tree2.save

    tree_ids = [tree1.id, tree2.id].compact

    get_tree_ids = ->(root_id : String) {
      # Refer to ./spec_models for `Tree#by_root_id` query
      Tree.by_root_id(root_id).to_a.compact_map(&.id).sort!
    }

    # Check the correct
    get_tree_ids.call(roots.first).should eq [tree_ids.first]
    get_tree_ids.call(roots[1]).should eq tree_ids.sort
    get_tree_ids.call(roots[2]).should eq [tree_ids[1]]
  end
end
