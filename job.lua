-------------------------------------------------------------------------------
-- Job Class
--
-- It returns an object that represents the job with the provided JID
-------------------------------------------------------------------------------

-- This gets all the data associated with the job with the provided id. If the
-- job is not found, it returns nil. If found, it returns an object with the
-- appropriate properties
function QlessJob:data(...)
    local job = redis.call(
            'hmget', 'ql:j:' .. self.jid, 'jid', 'klass', 'state', 'queue',
            'worker', 'priority', 'expires', 'retries', 'remaining', 'data',
            'tags', 'history', 'failure')

    -- Return nil if we haven't found it
    if not job[1] then
        return nil
    end

    local data = {
        jid          = job[1],
        klass        = job[2],
        state        = job[3],
        queue        = job[4],
        worker       = job[5] or '',
        tracked      = redis.call(
            'zscore', 'ql:tracked', self.jid) ~= false,
        priority     = tonumber(job[6]),
        expires      = tonumber(job[7]) or 0,
        retries      = tonumber(job[8]),
        remaining    = tonumber(job[9]),
        data         = cjson.decode(job[10]),
        tags         = cjson.decode(job[11]),
        history      = cjson.decode(job[12] or '{}'),
        failure      = cjson.decode(job[13] or '{}'),
        dependents   = redis.call(
            'smembers', 'ql:j:' .. self.jid .. '-dependents'),
        dependencies = redis.call(
            'smembers', 'ql:j:' .. self.jid .. '-dependencies')
    }

    if #arg > 0 then
        -- This section could probably be optimized, but I wanted the interface
        -- in place first
        local response = {}
        for index, key in ipairs(arg) do
            table.insert(response, data[key])
        end
        return response
    else
        return data
    end
end

-- Complete a job and optionally put it in another queue, either scheduled or
-- to be considered waiting immediately. It can also optionally accept other
-- jids on which this job will be considered dependent before it's considered 
-- valid.
--
-- The variable-length arguments may be pairs of the form:
-- 
--      ('next'   , queue) : The queue to advance it to next
--      ('delay'  , delay) : The delay for the next queue
--      ('depends',        : Json of jobs it depends on in the new queue
--          '["jid1", "jid2", ...]')
---
function QlessJob:complete(now, worker, queue, data, ...)
    assert(worker, 'Complete(): Arg "worker" missing')
    assert(queue , 'Complete(): Arg "queue" missing')
    data = assert(cjson.decode(data),
        'Complete(): Arg "data" missing or not JSON: ' .. tostring(data))

    -- Read in all the optional parameters
    local options = {}
    for i = 1, #arg, 2 do options[arg[i]] = arg[i + 1] end
    
    -- Sanity check on optional args
    local nextq   = options['next']
    local delay   = assert(tonumber(options['delay'] or 0))
    local depends = assert(cjson.decode(options['depends'] or '[]'),
        'Complete(): Arg "depends" not JSON: ' .. tostring(options['depends']))

    -- Delay and depends are not allowed together
    if delay > 0 and #depends > 0 then
        error('Complete(): "delay" and "depends" are not allowed together')
    end

    -- Depends doesn't make sense without nextq
    if options['delay'] and nextq == nil then
        error('Complete(): "delay" cannot be used without a "next".')
    end

    -- Depends doesn't make sense without nextq
    if options['depends'] and nextq == nil then
        error('Complete(): "depends" cannot be used without a "next".')
    end

    -- The bin is midnight of the provided day
    -- 24 * 60 * 60 = 86400
    local bin = now - (now % 86400)

    -- First things first, we should see if the worker still owns this job
    local lastworker, history, state, priority, retries = unpack(
        redis.call('hmget', 'ql:j:' .. self.jid, 'worker', 'history', 'state',
            'priority', 'retries', 'dependents'))

    if lastworker ~= worker then
        error('Complete(): Job has been handed out to another worker: ' ..
            lastworker)
    elseif (state ~= 'running') then
        error('Complete(): Job is not currently running: ' .. state)
    end

    -- Now we can assume that the worker does own the job. We need to
    --    1) Remove the job from the 'locks' from the old queue
    --    2) Enqueue it in the next stage if necessary
    --    3) Update the data
    --    4) Mark the job as completed, remove the worker, remove expires, and update history

    -- Unpack the history, and update it
    history = cjson.decode(history)
    history[#history]['done'] = math.floor(now)

    if data then
        redis.call('hset', 'ql:j:' .. self.jid, 'data', cjson.encode(data))
    end

    -- Remove the job from the previous queue
    local queue_obj = Qless.queue(queue)
    queue_obj.work.remove(self.jid)
    queue_obj.locks.remove(self.jid)
    queue_obj.scheduled.remove(self.jid)

    ----------------------------------------------------------
    -- This is the massive stats update that we have to do
    ----------------------------------------------------------
    -- This is how long we've been waiting to get popped
    local waiting = math.floor(now) - history[#history]['popped']
    Qless.queue(queue):stat(now, 'run', waiting)

    -- Remove this job from the jobs that the worker that was running it has
    redis.call('zrem', 'ql:w:' .. worker .. ':jobs', self.jid)

    if redis.call('zscore', 'ql:tracked', self.jid) ~= false then
        redis.call('publish', 'completed', self.jid)
    end

    if nextq then
        queue_obj = Qless.queue(nextq)
        -- Send a message out to log
        redis.call('publish', 'log', cjson.encode({
            jid   = self.jid,
            event = 'advanced',
            queue = queue,
            to    = nextq
        }))

        -- Enqueue the job
        table.insert(history, {
            q     = nextq,
            put   = math.floor(now)
        })

        -- We're going to make sure that this queue is in the
        -- set of known queues
        if redis.call('zscore', 'ql:queues', nextq) == false then
            redis.call('zadd', 'ql:queues', now, nextq)
        end
        
        redis.call('hmset', 'ql:j:' .. self.jid, 'state', 'waiting', 'worker',
            '', 'failure', '{}', 'queue', nextq, 'expires', 0, 'history',
            cjson.encode(history), 'remaining', tonumber(retries))
        
        if delay > 0 then
            queue_obj.scheduled.add(now + delay, self.jid)
            return 'scheduled'
        else
            -- These are the jids we legitimately have to wait on
            local count = 0
            for i, j in ipairs(depends) do
                -- Make sure it's something other than 'nil' or complete.
                local state = redis.call('hget', 'ql:j:' .. j, 'state')
                if (state and state ~= 'complete') then
                    count = count + 1
                    redis.call(
                        'sadd', 'ql:j:' .. j .. '-dependents',self.jid)
                    redis.call(
                        'sadd', 'ql:j:' .. self.jid .. '-dependencies', j)
                end
            end
            if count > 0 then
                queue_obj.depends.add(now, self.jid)
                redis.call('hset', 'ql:j:' .. self.jid, 'state', 'depends')
                return 'depends'
            else
                queue_obj.work.add(now, priority, self.jid)
                return 'waiting'
            end
        end
    else
        -- Send a message out to log
        redis.call('publish', 'log', cjson.encode({
            jid   = self.jid,
            event = 'completed',
            queue = queue
        }))

        redis.call('hmset', 'ql:j:' .. self.jid, 'state', 'complete', 'worker', '', 'failure', '{}',
            'queue', '', 'expires', 0, 'history', cjson.encode(history), 'remaining', tonumber(retries))
        
        -- Do the completion dance
        local count = Qless.config.get('jobs-history-count')
        local time  = Qless.config.get('jobs-history')
        
        -- These are the default values
        count = tonumber(count or 50000)
        time  = tonumber(time  or 7 * 24 * 60 * 60)
        
        -- Schedule this job for destructination eventually
        redis.call('zadd', 'ql:completed', now, self.jid)
        
        -- Now look at the expired job data. First, based on the current time
        local jids = redis.call('zrangebyscore', 'ql:completed', 0, now - time)
        -- Any jobs that need to be expired... delete
        for index, jid in ipairs(jids) do
            local tags = cjson.decode(redis.call('hget', 'ql:j:' .. jid, 'tags') or '{}')
            for i, tag in ipairs(tags) do
                redis.call('zrem', 'ql:t:' .. tag, jid)
                redis.call('zincrby', 'ql:tags', -1, tag)
            end
            redis.call('del', 'ql:j:' .. jid)
        end
        -- And now remove those from the queued-for-cleanup queue
        redis.call('zremrangebyscore', 'ql:completed', 0, now - time)
        
        -- Now take the all by the most recent 'count' ids
        jids = redis.call('zrange', 'ql:completed', 0, (-1-count))
        for index, jid in ipairs(jids) do
            local tags = cjson.decode(redis.call('hget', 'ql:j:' .. jid, 'tags') or '{}')
            for i, tag in ipairs(tags) do
                redis.call('zrem', 'ql:t:' .. tag, jid)
                redis.call('zincrby', 'ql:tags', -1, tag)
            end
            redis.call('del', 'ql:j:' .. jid)
        end
        redis.call('zremrangebyrank', 'ql:completed', 0, (-1-count))
        
        -- Alright, if this has any dependents, then we should go ahead
        -- and unstick those guys.
        for i, j in ipairs(redis.call('smembers', 'ql:j:' .. self.jid .. '-dependents')) do
            redis.call('srem', 'ql:j:' .. j .. '-dependencies', self.jid)
            if redis.call('scard', 'ql:j:' .. j .. '-dependencies') == 0 then
                local q, p = unpack(redis.call('hmget', 'ql:j:' .. j, 'queue', 'priority'))
                if q then
                    local queue = Qless.queue(q)
                    queue.depends.remove(j)
                    queue.work.add(now, p, j)
                    redis.call('hset', 'ql:j:' .. j, 'state', 'waiting')
                end
            end
        end
        
        -- Delete our dependents key
        redis.call('del', 'ql:j:' .. self.jid .. '-dependents')
        
        return 'complete'
    end
end

-- Fail(jid, worker, group, message, now, [data])
-- -------------------------------------------------
-- Mark the particular job as failed, with the provided group, and a more
-- specific message. By `group`, we mean some phrase that might be one of
-- several categorical modes of failure. The `message` is something more
-- job-specific, like perhaps a traceback.
-- 
-- This method should __not__ be used to note that a job has been dropped or
-- has failed in a transient way. This method __should__ be used to note that
-- a job has something really wrong with it that must be remedied.
-- 
-- The motivation behind the `group` is so that similar errors can be grouped
-- together. Optionally, updated data can be provided for the job. A job in
-- any state can be marked as failed. If it has been given to a worker as a 
-- job, then its subsequent requests to heartbeat or complete that job will
-- fail. Failed jobs are kept until they are canceled or completed.
--
-- __Returns__ the id of the failed job if successful, or `False` on failure.
--
-- Args:
--    1) jid
--    2) worker
--    3) group
--    4) message
--    5) the current time
--    6) [data]
function QlessJob:fail(now, worker, group, message, data)
    local worker  = assert(worker           , 'Fail(): Arg "worker" missing')
    local group   = assert(group            , 'Fail(): Arg "group" missing')
    local message = assert(message          , 'Fail(): Arg "message" missing')

    -- The bin is midnight of the provided day
    -- 24 * 60 * 60 = 86400
    local bin = now - (now % 86400)

    if data then
        data = cjson.decode(data)
    end

    -- First things first, we should get the history
    local history, queue, state = unpack(redis.call('hmget', 'ql:j:' .. self.jid, 'history', 'queue', 'state'))

    -- If the job has been completed, we cannot fail it
    if state ~= 'running' then
        error('Fail(): Job not currently running: ' .. state)
    end

    -- Send out a log message
    redis.call('publish', 'log', cjson.encode({
        jid     = self.jid,
        event   = 'failed',
        worker  = worker,
        group   = group,
        message = message
    }))

    if redis.call('zscore', 'ql:tracked', self.jid) ~= false then
        redis.call('publish', 'failed', self.jid)
    end

    -- Remove this job from the jobs that the worker that was running it has
    redis.call('zrem', 'ql:w:' .. worker .. ':jobs', self.jid)

    -- Now, take the element of the history for which our provided worker is the worker, and update 'failed'
    history = cjson.decode(history or '[]')
    if #history > 0 then
        for i=#history,1,-1 do
            if history[i]['worker'] == worker then
                history[i]['failed'] = math.floor(now)
            end
        end
    else
        history = {
            {
                worker = worker,
                failed = math.floor(now)
            }
        }
    end

    -- Increment the number of failures for that queue for the
    -- given day.
    redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failures', 1)
    redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. queue, 'failed'  , 1)

    -- Now remove the instance from the schedule, and work queues for the queue it's in
    local queue_obj = Qless.queue(queue)
    queue_obj.work.remove(self.jid)
    queue_obj.locks.remove(self.jid)
    queue_obj.scheduled.remove(self.jid)

    -- The reason that this appears here is that the above will fail if the job doesn't exist
    if data then
        redis.call('hset', 'ql:j:' .. self.jid, 'data', cjson.encode(data))
    end

    redis.call('hmset', 'ql:j:' .. self.jid, 'state', 'failed', 'worker', '',
        'expires', '', 'history', cjson.encode(history), 'failure', cjson.encode({
            ['group']   = group,
            ['message'] = message,
            ['when']    = math.floor(now),
            ['worker']  = worker
        }))

    -- Add this group of failure to the list of failures
    redis.call('sadd', 'ql:failures', group)
    -- And add this particular instance to the failed groups
    redis.call('lpush', 'ql:f:' .. group, self.jid)

    -- Here is where we'd intcrement stats about the particular stage
    -- and possibly the workers

    return self.jid
end

-- retry(0, now, queue, worker, [delay])
-- ------------------------------------------
-- This script accepts jid, queue, worker and delay for
-- retrying a job. This is similar in functionality to 
-- `put`, except that this counts against the retries 
-- a job has for a stage.
--
-- If the worker is not the worker with a lock on the job,
-- then it returns false. If the job is not actually running,
-- then it returns false. Otherwise, it returns the number
-- of retries remaining. If the allowed retries have been
-- exhausted, then it is automatically failed, and a negative
-- number is returned.
function QlessJob:retry(now, queue, worker, delay)
    assert(queue , 'Retry(): Arg "queue" missing')
    assert(worker, 'Retry(): Arg "worker" missing')
    delay = assert(tonumber(delay or 0),
        'Retry(): Arg "delay" not a number: ' .. tostring(delay))
    
    -- Let's see what the old priority, history and tags were
    local oldqueue, state, retries, oldworker, priority = unpack(redis.call('hmget', 'ql:j:' .. self.jid, 'queue', 'state', 'retries', 'worker', 'priority'))

    -- If this isn't the worker that owns
    if oldworker ~= worker then
        error('Retry(): Job has been handed out to another worker: ' .. oldworker)
    elseif state ~= 'running' then
        error('Retry(): Job is not currently running: ' .. state)
    end

    -- Remove it from the locks key of the old queue
    Qless.queue(oldqueue).locks.remove(self.jid)

    local remaining = redis.call('hincrby', 'ql:j:' .. self.jid, 'remaining', -1)

    -- Remove this job from the worker that was previously working it
    redis.call('zrem', 'ql:w:' .. worker .. ':jobs', self.jid)

    if remaining < 0 then
        -- Now remove the instance from the schedule, and work queues for the queue it's in
        local group = 'failed-retries-' .. queue
        -- First things first, we should get the history
        local history = redis.call('hget', 'ql:j:' .. self.jid, 'history')
        -- Now, take the element of the history for which our provided worker is the worker, and update 'failed'
        history = cjson.decode(history or '[]')
        history[#history]['failed'] = now
        
        redis.call('hmset', 'ql:j:' .. self.jid, 'state', 'failed', 'worker', '',
            'expires', '', 'history', cjson.encode(history), 'failure', cjson.encode({
                ['group']   = group,
                ['message'] = 'Job exhausted retries in queue "' .. queue .. '"',
                ['when']    = now,
                ['worker']  = worker
            }))
        
        -- Add this type of failure to the list of failures
        redis.call('sadd', 'ql:failures', group)
        -- And add this particular instance to the failed types
        redis.call('lpush', 'ql:f:' .. group, self.jid)
    else
        -- Put it in the queue again with a delay. Like put()
        local queue_obj = Qless.queue(queue)
        if delay > 0 then
            queue_obj.scheduled.add(now + delay, self.jid)
            redis.call('hset', 'ql:j:' .. self.jid, 'state', 'scheduled')
        else
            queue_obj.work.add(now, priority, self.jid)
            redis.call('hset', 'ql:j:' .. self.jid, 'state', 'waiting')
        end
    end

    return remaining
end

-- Depends(0, jid,
--      ('on', [jid, [jid, [...]]]) |
--      ('off',
--          ('all' | [jid, [jid, [...]]]))
-------------------------------------------------------------------------------
-- Add or remove dependencies a job has. If 'on' is provided, the provided
-- jids are added as dependencies. If 'off' and 'all' are provided, then all
-- the current dependencies are removed. If 'off' is provided and the next
-- argument is not 'all', then those jids are removed as dependencies.
--
-- If a job is not already in the 'depends' state, then this call will return
-- false. Otherwise, it will return true
--
-- Args:
--    1) jid
function QlessJob:depends(now, command, ...)
    assert(command, 'Depends(): Arg "command" missing')
    if redis.call('hget', 'ql:j:' .. self.jid, 'state') ~= 'depends' then
        return false
    end

    if command == 'on' then
        -- These are the jids we legitimately have to wait on
        for i, j in ipairs(arg) do
            -- Make sure it's something other than 'nil' or complete.
            local state = redis.call('hget', 'ql:j:' .. j, 'state')
            if (state and state ~= 'complete') then
                redis.call('sadd', 'ql:j:' .. j .. '-dependents'  , self.jid)
                redis.call('sadd', 'ql:j:' .. self.jid .. '-dependencies', j)
            end
        end
        return true
    elseif command == 'off' then
        if arg[1] == 'all' then
            for i, j in ipairs(redis.call('smembers', 'ql:j:' .. self.jid .. '-dependencies')) do
                redis.call('srem', 'ql:j:' .. j .. '-dependents', self.jid)
            end
            redis.call('del', 'ql:j:' .. self.jid .. '-dependencies')
            local q, p = unpack(redis.call('hmget', 'ql:j:' .. self.jid, 'queue', 'priority'))
            if q then
                local queue_obj = Qless.queue(q)
                queue_obj.depends.remove(self.jid)
                queue_obj.work.add(now, p, self.jid)
                redis.call('hset', 'ql:j:' .. self.jid, 'state', 'waiting')
            end
        else
            for i, j in ipairs(arg) do
                redis.call('srem', 'ql:j:' .. j .. '-dependents', self.jid)
                redis.call('srem', 'ql:j:' .. self.jid .. '-dependencies', j)
                if redis.call('scard', 'ql:j:' .. self.jid .. '-dependencies') == 0 then
                    local q, p = unpack(redis.call('hmget', 'ql:j:' .. self.jid, 'queue', 'priority'))
                    if q then
                        local queue_obj = Qless.queue(q)
                        queue_obj.depends.remove(self.jid)
                        queue_obj.work.add(now, p, self.jid)
                        redis.call('hset', 'ql:j:' .. self.jid, 'state', 'waiting')
                    end
                end
            end
        end
        return true
    else
        error('Depends(): Argument "command" must be "on" or "off"')
    end
end

-- This scripts conducts a heartbeat for a job, and returns
-- either the new expiration or False if the lock has been
-- given to another node
--
-- Args:
--    1) now
--    2) worker
--    3) [data]
function QlessJob:heartbeat(now, worker, data)
    assert(worker, 'Heatbeat(): Arg "worker" missing')

    -- We should find the heartbeat interval for this queue
    -- heartbeat. First, though, we need to find the queue
    -- this particular job is in
    local queue     = redis.call('hget', 'ql:j:' .. self.jid, 'queue') or ''
    local expires   = now + tonumber(
        Qless.config.get(queue .. '-heartbeat') or
        Qless.config.get('heartbeat', 60))

    if data then
        data = cjson.decode(data)
    end

    -- First, let's see if the worker still owns this job, and there is a worker
    local job_worker = redis.call('hget', 'ql:j:' .. self.jid, 'worker')
    if job_worker ~= worker or #job_worker == 0 then
        error('Heartbeat(): Job has been handed out to another worker: ' .. job_worker)
    else
        -- Otherwise, optionally update the user data, and the heartbeat
        if data then
            -- I don't know if this is wise, but I'm decoding and encoding
            -- the user data to hopefully ensure its sanity
            redis.call('hmset', 'ql:j:' .. self.jid, 'expires', expires, 'worker', worker, 'data', cjson.encode(data))
        else
            redis.call('hmset', 'ql:j:' .. self.jid, 'expires', expires, 'worker', worker)
        end
        
        -- Update hwen this job was last updated on that worker
        -- Add this job to the list of jobs handled by this worker
        redis.call('zadd', 'ql:w:' .. worker .. ':jobs', expires, self.jid)
        
        -- And now we should just update the locks
        local queue = Qless.queue(redis.call('hget', 'ql:j:' .. self.jid, 'queue'))
        queue.locks.add(expires, self.jid)
        return expires
    end
end

-- priority(0, jid, priority)
-- --------------------------
-- Accepts a jid, and a new priority for the job. If the job 
-- doesn't exist, then return false. Otherwise, return the 
-- updated priority. If the job is waiting, then the change
-- will be reflected in the order in which it's popped
function QlessJob:priority(priority)
    priority = assert(tonumber(priority),
        'Priority(): Arg "priority" missing or not a number: ' .. tostring(priority))

    -- Get the queue the job is currently in, if any
    local queue = redis.call('hget', 'ql:j:' .. self.jid, 'queue')

    if queue == nil then
        return false
    elseif queue == '' then
        -- Just adjust the priority
        redis.call('hset', 'ql:j:' .. self.jid, 'priority', priority)
        return priority
    else
        -- Adjust the priority and see if it's a candidate for updating
        -- its priority in the queue it's currently in
        local queue_obj = Qless.queue(queue)
        if queue_obj.work.score(self.jid) then
            queue_obj.work.add(0, priority, self.jid)
        end
        redis.call('hset', 'ql:j:' .. self.jid, 'priority', priority)
        return priority
    end
end

-- Update the jobs' attributes with the provided dictionary
function QlessJob:update(data)
    local tmp = {}
    for k, v in pairs(data) do
        table.insert(tmp, k)
        table.insert(tmp, v)
    end
    redis.call('hmset', 'ql:j:' .. self.jid, unpack(tmp))
end
