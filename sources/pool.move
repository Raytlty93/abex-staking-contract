
module abex_staking::pool {
    use sui::math;
    use sui::event;
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, ID, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};

    use abex_staking::admin::AdminCap;

    // === objects ===

    struct Pool<phantom S, phantom R> has key {
        id: UID,
        enabled: bool,
        last_updated_time: u64,
        staked_amount: u64,
        reward: Balance<R>,
        start_time: u64,
        end_time: u64,
        acc_reward_per_share: u128,
        lock_duration: u64,
    }

    struct Credential<phantom S, phantom R> has key {
        id: UID,
        lock_until: u64,
        acc_reward_per_share: u128,
        staked: Balance<S>,
    }

    // === events ===

    struct CreatePoolEvent<phantom S, phantom R> has copy, drop {
        id: ID,
        start_time: u64,
        end_time: u64,
        lock_duration: u64,
    }

    struct SetEnabledEvent<phantom S, phantom R> has copy, drop {
        enabled: bool,
    }

    struct SetStartTimeEvent<phantom S, phantom R> has copy, drop {
        start_time: u64,
    }

    struct SetEndTimeEvent<phantom S, phantom R> has copy, drop {
        end_time: u64,
    }

    struct SetLockDurationEvent<phantom S, phantom R> has copy, drop {
        lock_duration: u64,
    }

    struct AddRewardEvent<phantom S, phantom R> has copy, drop {
        reward_amount: u64,
    }

    struct DepositEvent<phantom S, phantom R> has copy, drop {
        user: address,
        stake_amount: u64,
        lock_until: u64,
    }

    struct WithdrawEvent<phantom S, phantom R> has copy, drop {
        user: address,
        unstake_amount: u64,
        reward_amount: u64,
    }

    const SCALE_FACTOR: u128 = 1_000_000_000_000_000_000;

    const ERR_POOL_INACTIVE: u64 = 0;
    const ERR_INVALID_START_TIME: u64 = 1;
    const ERR_INVALID_END_TIME: u64 = 2;
    const ERR_INVALID_DEPOSIT_AMOUNT: u64 = 3;
    const ERR_INVALID_REWARD_AMOUNT: u64 = 4;
    const ERR_INVALID_WITHDRAW_AMOUNT: u64 = 5;
    const ERR_NOT_UNLOCKED: u64 = 6;
    const ERR_ALREADY_STARTED: u64 = 7;
    const ERR_ALREADY_ENDED: u64 = 8;
    const ERR_CAN_NOT_SET_END_TIME: u64 = 9;
    const ERR_CAN_NOT_CLEAR_CREDENTIAL: u64 = 10;

    fun pay_from_balance<T>(
        balance: Balance<T>,
        receiver: address,
        ctx: &mut TxContext,
    ) {
        if (balance::value(&balance) > 0) {
            transfer::public_transfer(coin::from_balance(balance, ctx), receiver);
        } else {
            balance::destroy_zero(balance);
        }
    }

    fun refresh_pool<S, R>(
        pool: &mut Pool<S, R>,
        timestamp: u64,
    ) {
        if (timestamp == pool.last_updated_time || timestamp < pool.start_time) {
            return
        };
        if (pool.last_updated_time == pool.end_time) {
            return
        };
        if (pool.staked_amount == 0) {
            return
        };
        if (timestamp > pool.end_time) {
            timestamp = pool.end_time;
        };

        let reward_amount = (balance::value(&pool.reward) as u128) * (timestamp - pool.last_updated_time as u128)
            / (pool.end_time - pool.last_updated_time as u128);
        pool.last_updated_time = timestamp;
        
        let reward_per_share = reward_amount * SCALE_FACTOR / (pool.staked_amount as u128);
        pool.acc_reward_per_share = pool.acc_reward_per_share + reward_per_share;
    }

    public entry fun create_pool<S, R>(
        _a: &AdminCap,
        clock: &Clock,
        start_time: u64,
        end_time: u64,
        lock_duration: u64,
        ctx: &mut TxContext,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(start_time >= timestamp, ERR_INVALID_START_TIME);
        assert!(end_time > start_time, ERR_INVALID_END_TIME);
        
        let uid = object::new(ctx);
        let id = object::uid_to_inner(&uid);
        transfer::share_object(
            Pool<S, R> {
                id: uid,
                enabled: true,
                last_updated_time: start_time,
                staked_amount: 0,
                reward: balance::zero(),
                start_time,
                end_time,
                acc_reward_per_share: 0,
                lock_duration,
            }
        );

        event::emit(CreatePoolEvent<S, R> {
            id,
            start_time,
            end_time,
            lock_duration,
        })
    }

    public entry fun set_enabled<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        enabled: bool,
    ) {
        pool.enabled = enabled;

        event::emit(SetEnabledEvent<S, R> { enabled })
    }

    public entry fun set_start_time<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        clock: &Clock,
        start_time: u64,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp < pool.start_time, ERR_ALREADY_STARTED);
        assert!(start_time >= timestamp && start_time < pool.end_time, ERR_INVALID_START_TIME);

        refresh_pool(pool, timestamp);
        pool.start_time = start_time;

        event::emit(SetStartTimeEvent<S, R> { start_time })
    }

    public entry fun set_end_time<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        clock: &Clock,
        end_time: u64,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);
        assert!(end_time > timestamp && end_time > pool.start_time, ERR_INVALID_END_TIME);

        refresh_pool(pool, timestamp);
        pool.end_time = end_time;

        event::emit(SetEndTimeEvent<S, R> { end_time })
    }

    public entry fun set_lock_duration<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        lock_duration: u64,
    ) {
        pool.lock_duration = lock_duration;

        event::emit(SetLockDurationEvent<S, R> { lock_duration })
    }

    public entry fun add_reward<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        reward: Coin<R>,
        _ctx: &mut TxContext,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);
        
        let reward_amount = coin::value(&reward);
        assert!(reward_amount > 0, ERR_INVALID_REWARD_AMOUNT);

        refresh_pool(pool, timestamp);
        coin::put(&mut pool.reward, reward);

        event::emit(AddRewardEvent<S, R> { reward_amount })
    }

    public entry fun deposit<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        stake: Coin<S>,
        ctx: &mut TxContext,
    ) {
        assert!(pool.enabled, ERR_POOL_INACTIVE);

        let stake_amount = coin::value(&stake);
        assert!(stake_amount > 0, ERR_INVALID_DEPOSIT_AMOUNT);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp < pool.end_time, ERR_ALREADY_ENDED);
        refresh_pool(pool, timestamp);

        let lock_until = timestamp + pool.lock_duration;
        let credential = Credential<S, R> {
            id: object::new(ctx),
            lock_until,
            acc_reward_per_share: pool.acc_reward_per_share,
            staked: coin::into_balance(stake),
        };
        pool.staked_amount = pool.staked_amount + stake_amount;
        
        let user = tx_context::sender(ctx);
        transfer::transfer(credential, user);

        event::emit(DepositEvent<S, R> {
            user,
            stake_amount,
            lock_until,
        })
    }

    public entry fun withdraw<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut Credential<S, R>,
        unstake_amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(pool.enabled, ERR_POOL_INACTIVE);

        let staked_amount = balance::value(&credential.staked);
        assert!(staked_amount >= unstake_amount, ERR_INVALID_WITHDRAW_AMOUNT);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp >= math::min(credential.lock_until, pool.end_time), ERR_NOT_UNLOCKED);

        refresh_pool(pool, timestamp);

        let reward_amount = ((pool.acc_reward_per_share - credential.acc_reward_per_share)
            * (staked_amount as u128) / SCALE_FACTOR as u64);
        credential.acc_reward_per_share = pool.acc_reward_per_share;

        let reward = balance::split(&mut pool.reward, reward_amount);
        let unstake = balance::split(&mut credential.staked, unstake_amount);
        pool.staked_amount = pool.staked_amount - unstake_amount;

        let user = tx_context::sender(ctx);
        pay_from_balance(reward, user, ctx);
        pay_from_balance(unstake, user, ctx);

        event::emit(WithdrawEvent<S, R> {
            user,
            unstake_amount,
            reward_amount,
        })
    }

    public entry fun clear_empty_credential<S, R>(
        credential: Credential<S, R>,
        _ctx: &mut TxContext,
    ) {
        assert!(balance::value(&credential.staked) == 0, ERR_CAN_NOT_CLEAR_CREDENTIAL);

        let Credential {
            id,
            lock_until: _,
            acc_reward_per_share: _,
            staked,
        } = credential;

        object::delete(id);
        balance::destroy_zero(staked);
    }
}