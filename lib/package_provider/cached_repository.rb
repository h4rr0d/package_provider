require 'timeout'
require 'package_provider/repository'

module PackageProvider
  # Class representing cached repository to avoid multiple cloninng
  class CachedRepository < PackageProvider::Repository
    class CloneInProgress < StandardError
    end

    class RepoServantDoesNotMatch < StandardError
    end

    PACKAGE_PART_READY = '.package_part_ready'
    CLONE_LOCK = '.clone_lock'
    ERROR = '.error'

    class << self
      def cached?(req)
        repo_ready?(cache_dir(req))
      end

      def cache_dir(req)
        File.join(PackageProvider.config.repository_cache_root, req.fingerprint)
      end

      def repo_ready?(path)
        (repo_prepared?(path) || repo_error?(path)) && !repo_clonning?(path)
      end

      def repo_error!(path, message)
        File.open(path + ERROR, 'w+') { |f| f.puts(message) }
      end

      def repo_ready!(path)
        FileUtils.touch(path + PACKAGE_PART_READY)
      end

      private

      def repo_prepared?(path)
        Dir.exist?(path) && File.exist?(path + PACKAGE_PART_READY)
      end

      def repo_error?(path)
        File.exist?(path + PACKAGE_PART_READY) && File.exist?(path + ERROR)
      end

      def repo_clonning?(path)
        File.exist?(path + CLONE_LOCK)
      end
    end

    def cached_clone(req)
      fail RepoServantDoesNotMatch unless req.repo == @repo_url
      cached_dir = CachedRepository.cache_dir(req)
      if CachedRepository.repo_ready?(cached_dir)
        Metriks.meter('packageprovider.repository.cached').mark
        Metriks.meter("packageprovider.repository.#{metriks_key}.cached").mark
        return cached_dir
      end

      locked_file = lock_repo(cached_dir)
      perform_and_handle_clone(req, cached_dir)
      CachedRepository.repo_ready!(cached_dir)

      cached_dir
    ensure
      unlock_repo(locked_file)
    end

    private

    def logger
      PackageProvider.logger
    end

    def lock_repo(path)
      lock_file = path + CLONE_LOCK
      Timeout.timeout(2) do
        f = File.open(lock_file, File::RDWR | File::CREAT, 0644)
        f.flock(File::LOCK_EX)
        logger.info("Lock file #{lock_file}")
        f
      end
    rescue Timeout::Error
      Metriks.meter('packageprovider.repository.locked').mark
      Metriks.meter("packageprovider.repository.#{metriks_key}.locked").mark
      raise CloneInProgress
    end

    def handle_clone_error(cached_dir, error)
      if error.exit_code == 128
        error.message.prepend('Some requested folders do not exist or commit hash does not exist.')
      end

      CachedRepository.repo_error!(cached_dir, error.message)
    end

    def unlock_repo(f)
      logger.info('Unlocking repo')
      return unless f
      logger.info("Delete file #{f.path}")
      File.delete(f.path)
    end

    def perform_and_handle_clone(req, cached_dir)
      logger.info("Started clonning: #{req.inspect}")
      clone(cached_dir, req.commit_hash, req.checkout_mask, req.submodules?)
    rescue PackageProvider::Repository::CannotCloneRepo => err
      handle_clone_error(cached_dir, err)
    rescue PackageProvider::Repository::CannotFetchRepo => err
      CachedRepository.repo_error!(cached_dir, err)
    rescue => err
      logger.error("Clone exception: #{req.inspect} into #{cached_dir} err: #{err}")
      FileUtils.rm_rf(cached_dir)
      raise
    end
  end
end
