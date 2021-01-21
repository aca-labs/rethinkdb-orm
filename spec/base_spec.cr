require "./spec_helper"

describe RethinkORM::Base do
  it "should be comparable to other objects" do
    base = BasicModel.create(name: "joe")
    base1 = BasicModel.create(name: "joe")

    base.should eq base
    base.should be base

    base.should_not eq base1

    same_base = BasicModel.find(base.id.not_nil!)
    base.should eq same_base
    base.should_not be same_base
    base1.should_not eq same_base

    base.destroy
    base1.destroy
  end

  it "should load database responses" do
    base = BasicModel.create(name: "joe")

    base_found = BasicModel.find!(base.id.as(String))

    base_found.id.should eq base.id
    base_found.should eq base
    base_found.should_not be base
    base.destroy
  end

  it "should support serialisation" do
    base = BasicModel.create(name: "joe")
    base_id = base.id
    base.to_json.should eq ({id: base_id, name: "joe", age: 0}.to_json)

    base.destroy
  end

  it "should support dirty attributes" do
    begin
      base = BasicModel.new
      changed_attributes = base.changed_attributes

      base.name = "change"
      base.changed_attributes.size.should eq (changed_attributes.size + 1)

      base = BasicModel.new(name: "bob")
      base.changed_attributes.empty?.should be_false

      # A saved model should have no changes
      base = BasicModel.create(name: "joe")
      base.changed_attributes.empty?.should be_true
    ensure
      base.destroy if base && base.id
    end
  end
end
