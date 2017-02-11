RSpec.describe Dory::Dnsmasq do
  let(:dory_config) do
    %q(---
      :dory:
        :dnsmasq:
          :enabled: true
          :domains:
            - :domain: docker_test_name
              :address: 192.168.11.1
            - :domain: docker_second
              :address: 192.168.11.2
          :container_name: dory_dnsmasq_test_name
          :kill_others: false
    ).split("\n").map{|s| s.sub(' ' * 6, '')}.join("\n")
  end

  let(:dory_old_config) do
    %q(---
      :dory:
        :dnsmasq:
          :enabled: true
          :domain: docker_test_name
          :address: 192.168.11.1
          :container_name: dory_dnsmasq_test_name
    ).split("\n").map{|s| s.sub(' ' * 6, '')}.join("\n")
  end

  let(:dory_config_dinghy) do
    %q(---
      :dory:
        :dnsmasq:
          :enabled: true
          :domains:
            - :domain: docker_test_name
              :address: dinghy
            - :domain: docker_second
              :address: dingy  # not an accident
          :container_name: dory_dnsmasq_test_name
    ).split("\n").map{|s| s.sub(' ' * 6, '')}.join("\n")
  end

  def start_service_on_53
    puts "Requesting sudo to start an ncat listener on 53"
    `sudo echo 'Got sudo. starting ncat listener'`
    Process.spawn('sudo ncat -l 53')
    sleep(0.5)  # give the process time to bind
  end

  def cleanup_53
    Dory::Sh.run_command('sudo killall ncat')
    Dory::Sh.run_command('sudo killall exe')
  end

  before :all do
    cleanup_53
  end

  after :all do
    Dory::Dnsmasq.delete
  end

  it "has the docker client" do
    expect(Dory::Dnsmasq.docker_installed?).to be_truthy
  end

  it "respects settings (Using defaults)" do
    allow(Dory::Config).to receive(:filename) { "/tmp/doesnotexist.lies" }
    allow(Dory::Config).to receive(:default_yaml) { dory_config }
    expect(Dory::Dnsmasq.container_name).to eq('dory_dnsmasq_test_name')
    expect(Dory::Dnsmasq.domains).to eq([
      { 'domain' => 'docker_test_name', 'address' => '192.168.11.1' },
      { 'domain' => 'docker_second', 'address' => '192.168.11.2' }
    ])
  end

  it "starts up the container" do
    Dory::Dnsmasq.delete
    expect(Dory::Dnsmasq).not_to be_running
    expect{Dory::Dnsmasq.start}.to change{Dory::Dnsmasq.running?}.from(false).to(true)
    expect(Dory::Dnsmasq).to be_container_exists
  end

  it "doesn't fail when starting the container twice" do
    2.times{ expect{Dory::Dnsmasq.start}.not_to raise_error }
    expect(Dory::Dnsmasq).to be_running
  end

  it "deletes the container" do
    expect(Dory::Dnsmasq.start).to be_truthy
    expect(Dory::Dnsmasq).to be_running
    expect(Dory::Dnsmasq).to be_container_exists
    expect{Dory::Dnsmasq.delete}.to change{Dory::Dnsmasq.container_exists?}.from(true).to(false)
    expect(Dory::Dnsmasq).not_to be_running
  end

  it "stops the container" do
    expect(Dory::Dnsmasq.start).to be_truthy
    expect(Dory::Dnsmasq).to be_running
    expect(Dory::Dnsmasq.stop).to be_truthy
    expect(Dory::Dnsmasq).to be_container_exists
    expect(Dory::Dnsmasq).not_to be_running
  end

  it "starts the container when it already exists" do
    expect(Dory::Dnsmasq.start).to be_truthy
    expect(Dory::Dnsmasq).to be_running
    expect(Dory::Dnsmasq.stop).to be_truthy
    expect(Dory::Dnsmasq).to be_container_exists
    expect{Dory::Dnsmasq.start}.to change{Dory::Dnsmasq.running?}.from(false).to(true)
    expect(Dory::Dnsmasq).to be_container_exists
    expect(Dory::Dnsmasq).to be_running
  end

  it "handles an old (single) domain properly" do
    allow(Dory::Config).to receive(:filename) { "/tmp/doesnotexist.lies" }
    allow(Dory::Config).to receive(:default_yaml) { dory_old_config }
    expect(Dory::Dnsmasq.old_domain).to eq('docker_test_name')
    expect(Dory::Dnsmasq.old_address).to eq('192.168.11.1')
    expect(Dory::Dnsmasq.domain_addr_arg_string).to eq('docker_test_name 192.168.11.1')
  end

  it "handles an array of domains properly" do
    allow(Dory::Config).to receive(:filename) { "/tmp/doesnotexist.lies" }
    allow(Dory::Config).to receive(:default_yaml) { dory_config }
    expect(Dory::Dnsmasq.old_domain).to be_nil
    expect(Dory::Dnsmasq.old_address).to be_nil
    expect(Dory::Dnsmasq.domain_addr_arg_string).to eq(
      'docker_test_name 192.168.11.1 docker_second 192.168.11.2'
    )
  end

  it "slurps the ip from dinghy if set" do
    allow(Dory::Config).to receive(:filename) { "/tmp/doesnotexist.lies" }
    allow(Dory::Config).to receive(:default_yaml) { dory_config_dinghy }
    allow(Dory::Dinghy).to receive(:ip) { '1.1.1.1' }
    expect(Dory::Dnsmasq.address('dinghy')).to eq('1.1.1.1')
    expect(Dory::Dnsmasq.domain_addr_arg_string).to match(/1\.1\.1\.1/)
  end

  it "fails if dinghy doesn't return an ip address" do
    allow(Dory::Config).to receive(:filename) { "/tmp/doesnotexist.lies" }
    allow(Dory::Config).to receive(:default_yaml) { dory_config_dinghy }
    allow(Dory::Bash).to receive(:run_command) { OpenStruct.new(stdout: "something totally wrong\n") }
    expect{ Dory::Dnsmasq.address('dinghy') }.to raise_error(Dory::Dinghy::DinghyError)
    expect{ Dory::Dnsmasq.domain_addr_arg_string }.to raise_error(Dory::Dinghy::DinghyError)
  end

  context 'pre-existing listener on 53' do
    let(:port) { 53 }

    before(:all) { expect(Dory::Dnsmasq.stop).to be_truthy }

    before(:each) { start_service_on_53 }
    after(:each) { cleanup_53 }

    it "detects listening services" do
      expect(Dory::Dnsmasq.check_port(port).count).to eq(2)
      Dory::Dnsmasq.check_port(port).each { |p| expect(p.command).to match(/^(ncat|exe)$/) }
    end

    it "kills listening services" do
      expect(Dory::Dnsmasq.check_port(port)).not_to be_empty
      expect(Dory::Dnsmasq.offer_to_kill(Dory::Dnsmasq.check_port(port), answer: 'y')).to be_truthy
      expect(Dory::Dnsmasq.check_port(port)).to be_empty
    end

    it "doesn't kill the listening services if declined" do
      expect(Dory::Dnsmasq.check_port(port)).not_to be_empty
      expect(Dory::Dnsmasq.offer_to_kill(Dory::Dnsmasq.check_port(port), answer: 'n')).to be_falsey
      expect(Dory::Dnsmasq.check_port(port)).not_to be_empty
    end
  end

  context 'specified port' do
    let(:stub_settings) do
      ->(new_settings) do
        allow(Dory::Config).to receive(:settings) { new_settings }
      end
    end

    context 'linux' do
      it 'always returns port 53 on linux' do
        port = 53
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker' }}})
        expect(Dory::Dnsmasq.port).to eq(port)
        expect(Dory::Dnsmasq.run_command).to match(/-p.#{port}:#{port}\/tcp.-p.#{port}:#{port}\/udp/)
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker', port: 9999 }}})
        expect(Dory::Dnsmasq.port).to eq(port)
        expect(Dory::Dnsmasq.run_command).to match(/-p.#{port}:#{port}\/tcp.-p.#{port}:#{port}\/udp/)
      end
    end

    context 'macos' do
      before(:each) do
        allow(Dory::Os).to receive(:macos?) { true }
      end

      after(:each) do
        allow(Dory::Os).to receive(:macos?).and_call_original
      end

      it 'defaults port to 19323 on macos' do
        stub_settings.call({ dory: { dnsmasq: {}}})
        expect(Dory::Dnsmasq.port).to eq(19323)
      end

      it 'respects the port setting on macos' do
        port = 9999
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker', port: port }}})
        expect(Dory::Dnsmasq.port).to eq(port)
        expect(Dory::Dnsmasq.run_command).to match(/-p.#{port}:#{port}\/tcp.-p.#{port}:#{port}\/udp/)
      end

      it 'sanitizes the port input' do
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker', port: '9999' }}})
        expect(Dory::Dnsmasq.port).to eq(9999)
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker', port: '999a' }}})
        expect(Dory::Dnsmasq.port).to eq(999)
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker', port: '999;' }}})
        expect(Dory::Dnsmasq.port).to eq(999)
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker', port: '999"' }}})
        expect(Dory::Dnsmasq.port).to eq(999)
        stub_settings.call({ dory: { dnsmasq: { domain: 'docker', port: '999\'' }}})
        expect(Dory::Dnsmasq.port).to eq(999)
      end
    end
  end

  context 'kill others setting' do
    let(:stub_settings) do
      ->(new_settings) do
        allow(Dory::Config).to receive(:settings) { new_settings }
      end
    end

    it '#kill_others pulls the settings out' do
      stub_settings.call({ dory: { dnsmasq: { kill_others: 'yo' }}})
      expect(Dory::Dnsmasq.kill_others).to eq('yo')
    end

    {
      true => 'Y',
      'yes' => 'Y',
      false => 'N',
      'no' => 'N',
      'ask' => nil,
      'something-wrong' => nil
    }.each do |value, expected|
      it "#answer_from_settings handles #{value}" do
        stub_settings.call({ dory: { dnsmasq: { kill_others: value }}})
        expect(Dory::Dnsmasq.answer_from_settings).to eq(expected)
      end

      it "#ask_about_killing handles #{value}" do
        stub_settings.call({ dory: { dnsmasq: { kill_others: value }}})
        expect(Dory::Dnsmasq.ask_about_killing?).to eq(expected == nil)
      end
    end
  end

  context 'smoke test' do
    it 'runs the command (smoke test)' do
      got_called = false
      allow(Dory::Dnsmasq).to receive(:has_systemd?) { false }
      allow(Dory::Dnsmasq).to receive(:delete_container_if_exists) { true }
      allow(Dory::Dnsmasq).to receive(:run_preconditions) { true }
      allow(Dory::Dnsmasq).to receive(:run_postconditions) { true }
      allow(Dory::Sh).to receive(:run_command) do
        got_called = true
        OpenStruct.new(success?: true)
      end
      expect {
        Dory::Dnsmasq.execute_run_command(handle_error: true)
      }.to change{ got_called }.from(false).to(true)
    end
  end
end
