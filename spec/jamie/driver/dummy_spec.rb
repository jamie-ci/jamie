# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2012, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative '../../spec_helper'

require 'jamie/driver/dummy'

describe Jamie::Driver::Dummy do

  let(:logged_output) { StringIO.new }
  let(:logger)        { Logger.new(logged_output) }
  let(:config)        { Hash.new }
  let(:state)         { Hash.new }

  let(:instance) do
    stub(:name => "coolbeans", :logger => logger, :to_str => "instance")
  end

  let(:driver) do
    d = Jamie::Driver::Dummy.new(config)
    d.instance = instance
    d
  end

  describe "default_config" do

    it "sets :sleep to 0 by default" do
      driver[:sleep].must_equal 0
    end

    it "sets :random_failure to false by default" do
      driver[:random_failure].must_equal false
    end
  end

  describe "#create" do

    it "sets :my_id to a unique value as an example" do
      driver.create(state)

      state[:my_id].must_match /^coolbeans-/
    end

    it "calls sleep if :sleep value is greater than 0" do
      config[:sleep] = 12.5
      driver.expects(:sleep).with(12.5).returns(true)

      driver.create(state)
    end

    it "randomly raises ActionFailed if :random_failure is set" do
      config[:random_failure] = true
      driver.stubs(:randomly_fail?).returns(true)

      proc { driver.create(state) }.must_raise Jamie::ActionFailed
    end

    it "will only raise ActionFailed if :random_failure is set" do
      config[:random_failure] = true

      begin
        driver.create(state)
      rescue Jamie::ActionFailed => ex
        # If exception is anything other than Jamie::ActionFailed, this spec
        # will fail
      end
    end

    it "logs a create event to INFO" do
      driver.create(state)

      logged_output.string.must_match /^.+ INFO .+ \[Dummy\] Create on .+$/
    end
  end

  describe "#converge" do

    it "calls sleep if :sleep value is greater than 0" do
      config[:sleep] = 12.5
      driver.expects(:sleep).with(12.5).returns(true)

      driver.create(state)
    end

    it "randomly raises ActionFailed if :random_failure is set" do
      config[:random_failure] = true
      driver.stubs(:randomly_fail?).returns(true)

      proc { driver.converge(state) }.must_raise Jamie::ActionFailed
    end

    it "logs a converge event to INFO" do
      driver.converge(state)

      logged_output.string.must_match /^.+ INFO .+ \[Dummy\] Converge on .+$/
    end
  end

  describe "#setup" do

    it "calls sleep if :sleep value is greater than 0" do
      config[:sleep] = 12.5
      driver.expects(:sleep).with(12.5).returns(true)

      driver.setup(state)
    end

    it "randomly raises ActionFailed if :random_failure is set" do
      config[:random_failure] = true
      driver.stubs(:randomly_fail?).returns(true)

      proc { driver.setup(state) }.must_raise Jamie::ActionFailed
    end

    it "logs a setup event to INFO" do
      driver.setup(state)

      logged_output.string.must_match /^.+ INFO .+ \[Dummy\] Setup on .+$/
    end
  end

  describe "#verify" do

    it "calls sleep if :sleep value is greater than 0" do
      config[:sleep] = 12.5
      driver.expects(:sleep).with(12.5).returns(true)

      driver.verify(state)
    end

    it "randomly raises ActionFailed if :random_failure is set" do
      config[:random_failure] = true
      driver.stubs(:randomly_fail?).returns(true)

      proc { driver.verify(state) }.must_raise Jamie::ActionFailed
    end

    it "logs a verify event to INFO" do
      driver.verify(state)

      logged_output.string.must_match /^.+ INFO .+ \[Dummy\] Verify on .+$/
    end
  end

  describe "#destroy" do

    it "removes :my_id from the state hash" do
      state[:my_id] = "90210"
      driver.destroy(state)

      state[:my_id].must_be_nil
    end

    it "calls sleep if :sleep value is greater than 0" do
      config[:sleep] = 12.5
      driver.expects(:sleep).with(12.5).returns(true)

      driver.verify(state)
    end

    it "randomly raises ActionFailed if :random_failure is set" do
      config[:random_failure] = true
      driver.stubs(:randomly_fail?).returns(true)

      proc { driver.destroy(state) }.must_raise Jamie::ActionFailed
    end

    it "logs a destroy event to INFO" do
      driver.destroy(state)

      logged_output.string.must_match /^.+ INFO .+ \[Dummy\] Destroy on .+$/
    end
  end
end
