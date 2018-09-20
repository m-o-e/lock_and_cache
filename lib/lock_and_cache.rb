require 'logger'
require 'timeout'
require 'digest/sha1'
require 'base64'
require 'redis'
require 'active_support'
require 'active_support/core_ext'

require_relative 'lock_and_cache/version'
require_relative 'lock_and_cache/action'
require_relative 'lock_and_cache/key'

# Lock and cache using redis!
#
# Most caching libraries don't do locking, meaning that >1 process can be calculating a cached value at the same time. Since you presumably cache things because they cost CPU, database reads, or money, doesn't it make sense to lock while caching?
module LockAndCache
  DEFAULT_MAX_LOCK_WAIT = 60 * 60 * 24 # 1 day in seconds

  DEFAULT_HEARTBEAT_EXPIRES = 32 # 32 seconds

  class TimeoutWaitingForLock < StandardError; end

  # @param redis_connection [Redis] A redis connection to be used for lock storage
  def LockAndCache.lock_storage=(redis_connection)
    raise "only redis for now" unless redis_connection.class.to_s == 'Redis'
    @lock_storage = redis_connection
  end

  # @return [Redis] The redis connection used for lock and cached value storage
  def LockAndCache.lock_storage
    @lock_storage
  end

  # @param redis_connection [Redis] A redis connection to be used for cached value storage
  def LockAndCache.cache_storage=(redis_connection)
    raise "only redis for now" unless redis_connection.class.to_s == 'Redis'
    @cache_storage = redis_connection
  end

  # @return [Redis] The redis connection used for cached value storage
  def LockAndCache.cache_storage
    @cache_storage
  end

  # @param logger [Logger] A logger.
  def LockAndCache.logger=(logger)
    @logger = logger
  end

  # @return [Logger] The logger.
  def LockAndCache.logger
    @logger
  end

  # Flush LockAndCache's cached value storage.
  #
  # @note If you are sharing a redis database, it will clear it...
  #
  # @note If you want to clear a single key, try `LockAndCache.clear(key)` (standalone mode) or `#lock_and_cache_clear(method_id, *key_parts)` in context mode.
  def LockAndCache.flush_cache
    cache_storage.flushdb
  end

  # Flush LockAndCache's lock storage.
  #
  # @note If you are sharing a redis database, it will clear it...
  #
  # @note If you want to clear a single key, try `LockAndCache.clear(key)` (standalone mode) or `#lock_and_cache_clear(method_id, *key_parts)` in context mode.
  def LockAndCache.flush_locks
    lock_storage.flushdb
  end

  # Lock and cache based on a key.
  #
  # @param key_parts [*] Parts that should be used to construct a key.
  #
  # @note Standalone mode. See also "context mode," where you mix LockAndCache into a class and call it from within its methods.
  #
  # @note A single hash arg is treated as a cache key, e.g. `LockAndCache.lock_and_cache(foo: :bar, expires: 100)` will be treated as a cache key of `foo: :bar, expires: 100` (which is probably wrong!!!). Try `LockAndCache.lock_and_cache({ foo: :bar }, expires: 100)` instead. This is the opposite of context mode.
  def LockAndCache.lock_and_cache(*key_parts_and_options, &blk)
    options = (key_parts_and_options.last.is_a?(Hash) && key_parts_and_options.length > 1) ? key_parts_and_options.pop : {}
    raise "need a cache key" unless key_parts_and_options.length > 0
    key = LockAndCache::Key.new key_parts_and_options
    action = LockAndCache::Action.new key, options, blk
    action.perform
  end

  # Clear a single key
  #
  # @note Standalone mode. See also "context mode," where you mix LockAndCache into a class and call it from within its methods.
  def LockAndCache.clear(*key_parts)
    key = LockAndCache::Key.new key_parts
    key.clear
  end

  # Check if a key is locked
  #
  # @note Standalone mode. See also "context mode," where you mix LockAndCache into a class and call it from within its methods.
  def LockAndCache.locked?(*key_parts)
    key = LockAndCache::Key.new key_parts
    key.locked?
  end

  # Check if a key is cached already
  #
  # @note Standalone mode. See also "context mode," where you mix LockAndCache into a class and call it from within its methods.
  def LockAndCache.cached?(*key_parts)
    key = LockAndCache::Key.new key_parts
    key.cached?
  end

  # @param seconds [Numeric] Maximum wait time to get a lock
  #
  # @note Can be overridden by putting `max_lock_wait:` in your call to `#lock_and_cache`
  def LockAndCache.max_lock_wait=(seconds)
    @max_lock_wait = seconds.to_f
  end

  # @private
  def LockAndCache.max_lock_wait
    @max_lock_wait || DEFAULT_MAX_LOCK_WAIT
  end

  # @param seconds [Numeric] How often a process has to heartbeat in order to keep a lock
  #
  # @note Can be overridden by putting `heartbeat_expires:` in your call to `#lock_and_cache`
  def LockAndCache.heartbeat_expires=(seconds)
    memo = seconds.to_f
    raise "heartbeat_expires must be greater than 2 seconds" unless memo >= 2
    @heartbeat_expires = memo
  end

  # @private
  def LockAndCache.heartbeat_expires
    @heartbeat_expires || DEFAULT_HEARTBEAT_EXPIRES
  end

  # Check if a method is locked on an object.
  #
  # @note Subject mode - this is expected to be called on an object whose class has LockAndCache mixed in. See also standalone mode.
  def lock_and_cache_locked?(method_id, *key_parts)
    key = LockAndCache::Key.new key_parts, context: self, method_id: method_id
    key.locked?
  end

  # Clear a lock and cache given exactly the method and exactly the same arguments
  #
  # @note Subject mode - this is expected to be called on an object whose class has LockAndCache mixed in. See also standalone mode.
  def lock_and_cache_clear(method_id, *key_parts)
    key = LockAndCache::Key.new key_parts, context: self, method_id: method_id
    key.clear
  end

  # Lock and cache a method given key parts.
  #
  # The cache key will automatically include the class name of the object calling it (the context!) and the name of the method it is called from.
  #
  # @param key_parts_and_options [*] Parts that you want to include in the lock and cache key. If the last element is a Hash, it will be treated as options.
  #
  # @return The cached value (possibly newly calculated).
  #
  # @note Subject mode - this is expected to be called on an object whose class has LockAndCache mixed in. See also standalone mode.
  #
  # @note A single hash arg is treated as an options hash, e.g. `lock_and_cache(expires: 100)` will be treated as options `expires: 100`. This is the opposite of standalone mode.
  def lock_and_cache(*key_parts_and_options, &blk)
    options = key_parts_and_options.last.is_a?(Hash) ? key_parts_and_options.pop : {}
    key = LockAndCache::Key.new key_parts_and_options, context: self, caller: caller
    action = LockAndCache::Action.new key, options, blk
    action.perform
  end
end

logger = Logger.new $stderr
logger.level = (ENV['LOCK_AND_CACHE_DEBUG'] == 'true') ? Logger::DEBUG : Logger::INFO
LockAndCache.logger = logger
