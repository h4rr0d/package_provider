require 'package_provider/repository_connection_pool'
require 'package_provider/repository_config'
require 'package_provider/repository_request'
require 'sidekiq-unique-jobs'

# Package provider module
module PackageProvider
  # class performing caching repository as background job
  class RepositoryWorker
    include Sidekiq::Worker
    sidekiq_options queue: :clone_repository,
                    retry: PackageProvider.config.sidekiq.clone_retry_on_error,
                    unique: :until_executed,
                    log_duplicate_payload: PackageProvider.config.sidekiq.log_duplicate_payload

    def perform(request_as_json)
      request = PackageProvider::RepositoryRequest.from_json(request_as_json)
      PackageProvider.logger.info("performing clonning: #{request.to_tsd} #{request.fingerprint}")

      begin
        c_pool = ReposPool.fetch(request)

        PackageProvider.logger.debug("pool #{c_pool.inspect}")

        c_pool.with do |i|
          begin
            i.cached_clone(request)
          rescue PackageProvider::CachedRepository::CloneInProgress
            PackageProvider.logger.info("clone in progress: #{request.to_tsd}")
          end
        end

        PackageProvider.logger.info("clonning done #{request.to_tsd}")
      rescue Timeout::Error
        PackageProvider.logger.info("failed to obtain #{request.repo} connection from RepoPool")
        Metriks.meter("packageprovider.pool.#{request.repo}.missing").mark
      end
    end
  end
end
