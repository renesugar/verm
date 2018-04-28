require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

class ReplicationPropagationTest < Verm::TestCase
  def setup
    @slave = spawn_verm
    @master = spawn_verm(
      :verm_data => "#{@slave.verm_data}_replica",
      :port => @slave.port + 1,
      :replicate_to => @slave.host)
  end

  def assert_propagates_file(get_options)
    assert_statistics_change(:put_requests => 1, :put_requests_new_file_stored => 1, :get_requests => 1) do # on the slave
      before = get_statistics(:verm => @master)
  
      location = yield

      # wait until replication has been attempted
      after = changes = nil
      repeatedly_wait_until do
        after = get_statistics(:verm => @master)
        changes = calculate_statistics_change(before, after)
        changes[:replication_push_attempts]
      end

      assert_equal({:post_requests => 1, :post_requests_new_file_stored => 1, :replication_push_attempts => 1},
                   changes)
      assert_equal 0, after[:"replication_#{@slave.hostname}_#{@slave.port}_queue_length"]

      # check the slave now has it
      get get_options.merge(:path => location)
    end
  end

  def test_propagates_new_files_to_slave
    assert_propagates_file(:expected_content => File.read(fixture_file_path('simple_text_file'), :mode => 'rb')) do
      post_file :path => '/foo',
                :file => 'simple_text_file',
                :type => 'text/plain',
                :verm => @master
    end

    assert_propagates_file(:expected_content => File.read(fixture_file_path('binary_file'), :mode => 'rb')) do
      post_file :path => '/foo',
                :file => 'binary_file',
                :type => 'application/octet-stream',
                :verm => @master
    end

    assert_propagates_file(:expected_content => File.read(fixture_file_path('medium_file'), :mode => 'rb')) do
      post_file :path => '/foo',
                :file => 'medium_file',
                :type => 'application/octet-stream',
                :verm => @master
    end

    unless ENV['VALGRIND'] || ENV['NO_CAPTURE_STDERR'].to_i > 0
      assert_equal "", @master.stderr_output
    end
  end

  def test_propagates_compressed_files
    assert_propagates_file(:expected_content => File.read(fixture_file_path('binary_file.gz'), :mode => 'rb'),
                           :expected_content_type => "application/octet-stream",
                           :expected_content_encoding => 'gzip') do
      post_file :path => '/foo',
                :file => 'binary_file.gz',
                :encoding => 'gzip',
                :expected_extension_suffix => 'gz',
                :type => 'application/octet-stream',
                :verm => @master
    end

    unless ENV['VALGRIND'] || ENV['NO_CAPTURE_STDERR'].to_i > 0
      assert_equal "", @master.stderr_output
    end
  end

  def test_propagates_uploaded_gzip_files
    assert_propagates_file(:expected_content => File.read(fixture_file_path('simple_text_file.gz'), :mode => 'rb'),
                           :expected_content_type => "application/gzip",
                           :expected_content_encoding => nil) do
      post_file :path => '/foo',
                :file => 'simple_text_file.gz',
                :type => 'application/x-gzip',
                :expected_extension => 'gz', # note not expected_extension_suffix - we uploaded as a gzip file not a content-encoded plain file
                :verm => @master
    end

    unless ENV['VALGRIND'] || ENV['NO_CAPTURE_STDERR'].to_i > 0
      assert_equal "", @master.stderr_output
    end
  end

  def test_retries_propagation_if_slave_unavailable
    @slave.stop_verm

    before = get_statistics(:verm => @master)

    locations = [
      post_file(:path => '/foo',
                :file => 'another_text_file',
                :type => 'text/plain',
                :expected_extension => "txt",
                :verm => @master),
      post_file(:path => '/foo',
                :file => 'medium_file',
                :type => 'image/jpeg',
                :expected_extension => "jpg",
                :verm => @master),
      post_file(:path => '/foo',
                :file => 'binary_file.gz',
                :encoding => 'gzip',
                :expected_extension_suffix => 'gz',
                :type => 'application/octet-stream',
                :verm => @master),
      post_file(:path => '/foo',
                :file => 'simple_text_file.gz',
                :type => 'application/x-gzip',
                :expected_extension => 'gz', # note not expected_extension_suffix - we uploaded as a gzip file not a content-encoded plain file
                :verm => @master),
    ]

    after = changes = nil
    repeatedly_wait_until do
      after = get_statistics(:verm => @master)
      after[:replication_push_attempts] && after[:replication_push_attempts] > 0
    end

    changes = calculate_statistics_change(before, after)
    assert_equal changes.delete(:replication_push_attempts_failed), changes.delete(:replication_push_attempts)

    assert_equal({
      :post_requests => locations.size, :post_requests_new_file_stored => locations.size,
      :"replication_#{@slave.hostname}_#{@slave.port}_queue_length" => locations.size,
    }, changes)

    unless ENV['VALGRIND'] || ENV['NO_CAPTURE_STDERR'].to_i > 0
      assert_match(/#{@slave.port}:( (connect|getsockopt):)? connection refused/,
        @master.stderr_output.downcase,
        "replication error was not logged")
    end

    @slave.start_verm
    @slave.wait_until_available

    repeatedly_wait_until do
      after = get_statistics(:verm => @master)
      after[:replication_push_attempts] == after[:replication_push_attempts_failed] + locations.size
    end

    # check the slave now has the files in the same locations
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('another_text_file'), :mode => 'rb'), :expected_content_type => "text/plain", :expected_content_encoding => nil
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('medium_file'), :mode => 'rb'), :expected_content_type => "image/jpeg", :expected_content_encoding => nil
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('binary_file.gz'), :mode => 'rb'), :expected_content_type => "application/octet-stream", :expected_content_encoding => "gzip"
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('simple_text_file.gz'), :mode => 'rb'), :expected_content_type => "application/gzip", :expected_content_encoding => nil
  end

  def test_propagates_missing_files_if_restarted
    locations = [
      post_file(:path => '/foo',
                :file => 'another_text_file',
                :type => 'text/plain',
                :expected_extension => "txt",
                :verm => @master),
      post_file(:path => '/foo',
                :file => 'medium_file',
                :type => 'image/jpeg',
                :expected_extension => "jpg",
                :verm => @master),
      post_file(:path => '/foo',
                :file => 'binary_file.gz',
                :encoding => 'gzip',
                :expected_extension_suffix => 'gz',
                :type => 'application/octet-stream',
                :verm => @master),
      post_file(:path => '/foo',
                :file => 'simple_text_file.gz',
                :type => 'application/x-gzip',
                :expected_extension => 'gz', # note not expected_extension_suffix - we uploaded as a gzip file not a content-encoded plain file
                :verm => @master),
    ]

    @master.stop_verm
    @slave.clear_data
    @master.start_verm
    @master.wait_until_available

    after = nil
    repeatedly_wait_until do
      after = get_statistics(:verm => @master)
      after[:replication_push_attempts] == locations.size
    end

    assert_equal 4, after[:replication_push_attempts]
    assert_equal 0, after[:replication_push_attempts_failed]
    assert_equal 0, after[:"replication_#{@slave.hostname}_#{@slave.port}_queue_length"]

    # check the slave now has the files
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('another_text_file'), :mode => 'rb'), :expected_content_type => "text/plain", :expected_content_encoding => nil
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('medium_file'), :mode => 'rb'), :expected_content_type => "image/jpeg", :expected_content_encoding => nil
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('binary_file.gz'), :mode => 'rb'), :expected_content_type => "application/octet-stream", :expected_content_encoding => "gzip"
    get :path => locations.shift, :expected_content => File.read(fixture_file_path('simple_text_file.gz'), :mode => 'rb'), :expected_content_type => "application/gzip", :expected_content_encoding => nil
  end
end
