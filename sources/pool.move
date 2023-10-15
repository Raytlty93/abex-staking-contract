
module abex_staking::pool {
    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::tx_context:: {Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};

    use abex_staking::admin::AdminCap;
    use abex_staking::decimal::{Self, Decimal};

    struct Pool<phantom S, phantom R> has key {
        id: UID,
        enabled: bool,
        last_updated_time: u64,
        staked_amount: u64,
        reward: Balance<R>,
        start_time: u64,
        end_time: u64,
        acc_reward_per_share: Decimal,
        locked_duration: u64,
    }

    struct Credential<phantom S, phantom R> has key {
        id: UID,
        lock_until: u64,
        acc_reward_per_share: Decimal,
        staked: Balance<S>,
    }

    const ERR_POOL_INACTIVE: u64 = 0;
    const ERR_INVALID_START_TIME: u64 = 1;
    const ERR_INVALID_END_TIME: u64 = 2;
    const ERR_INVALID_DEPOSIT_AMOUNT: u64 = 3;
    const ERR_INVALID_REWARD_AMOUNT: u64 = 4;
    const ERR_INVALID_WITHDRAW_AMOUNT: u64 = 5;
    const ERR_NOT_UNLOCKED: u64 = 6;
    const ERR_CAN_NOT_CLEAR_CREDENTIAL: u64 = 7;

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
        
        let reward_amount = decimal::div_by_u64(
            decimal::mul_with_u64(
                decimal::from_u64(balance::value(&pool.reward)),
                timestamp - pool.last_updated_time,
            ),
            pool.end_time - pool.last_updated_time,
        );
        pool.last_updated_time = timestamp;

        let reward_per_share = decimal::div(
            reward_amount,
            decimal::from_u64(pool.staked_amount),
        );
        pool.acc_reward_per_share = decimal::add(
            pool.acc_reward_per_share,
            reward_per_share,
        );
    }

    public entry fun create_pool<S, R>(
        _a: &AdminCap,
        clock: &Clock,
        start_time: u64,
        end_time: u64,
        locked_duration: u64,
        ctx: &mut TxContext,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(start_time >= timestamp, ERR_INVALID_START_TIME);
        assert!(end_time > start_time, ERR_INVALID_END_TIME);
        
        transfer::share_object(
            Pool<S, R> {
                id: object::new(ctx),
                enabled: true,
                last_updated_time: start_time,
                staked_amount: 0,
                reward: balance::zero(),
                start_time,
                end_time,
                acc_reward_per_share: decimal::zero(),
                locked_duration,
            }
        )
    }

    public entry fun set_enabled<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        enabled: bool,
    ) {
        pool.enabled = enabled;
    }

    public entry fun set_start_time<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        clock: &Clock,
        start_time: u64,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(start_time >= timestamp, ERR_INVALID_START_TIME);
        assert!(start_time < pool.end_time, ERR_INVALID_START_TIME);

        refresh_pool(pool, timestamp);
        pool.start_time = start_time;
    }

    public entry fun set_end_time<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        clock: &Clock,
        end_time: u64,
    ) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(end_time > pool.start_time, ERR_INVALID_END_TIME);
        assert!(end_time > timestamp, ERR_INVALID_END_TIME);

        refresh_pool(pool, timestamp);
        pool.end_time = end_time;
    }

    public entry fun set_locked_duration<S, R>(
        _a: &AdminCap,
        pool: &mut Pool<S, R>,
        locked_duration: u64,
    ) {
        pool.locked_duration = locked_duration;
    }

    public entry fun add_reward<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        reward: Coin<R>,
        _ctx: &mut TxContext,
    ) {
        assert!(coin::value(&reward) > 0, ERR_INVALID_REWARD_AMOUNT);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        refresh_pool(pool, timestamp);
        coin::put(&mut pool.reward, reward);
    }

    public entry fun deposit<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        stake: Coin<S>,
        ctx: &mut TxContext,
    ) {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        assert!(coin::value(&stake) > 0, ERR_INVALID_DEPOSIT_AMOUNT);

        let timestamp = clock::timestamp_ms(clock) / 1000;
        refresh_pool(pool, timestamp);

        let credential = Credential<S, R> {
            id: object::new(ctx),
            lock_until: timestamp + pool.locked_duration,
            acc_reward_per_share: pool.acc_reward_per_share,
            staked: coin::into_balance(stake),
        };
        pool.staked_amount = pool.staked_amount + coin::value(&stake);
        
        transfer::transfer(credential, tx_context::sender(ctx));
    }

    public entry fun withdraw<S, R>(
        pool: &mut Pool<S, R>,
        clock: &Clock,
        credential: &mut Credential<S, R>,
        unstake_amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(pool.enabled, ERR_POOL_INACTIVE);
        assert!(
            balance::value(&credential.staked) >= unstake_amount,
            ERR_INVALID_WITHDRAW_AMOUNT,
        );

        let timestamp = clock::timestamp_ms(clock) / 1000;
        assert!(timestamp >= credential.lock_until, ERR_NOT_UNLOCKED);

        refresh_pool(pool, timestamp);

        let reward_amount = decimal::mul_with_u64(
            decimal::sub(
                pool.acc_reward_per_share,
                credential.acc_reward_per_share,
            ),
            balance::value(&credential.staked),
        );
        let reward_amount = decimal::floor_u64(reward_amount);
        credential.acc_reward_per_share = pool.acc_reward_per_share;

        let reward = balance::split(&mut pool.reward, reward_amount);
        let unstake = balance::split(&mut credential.staked, unstake_amount);
        pool.staked_amount = pool.staked_amount - unstake_amount;

        let receiver = tx_context::sender(ctx);
        pay_from_balance(reward, receiver, ctx);
        pay_from_balance(unstake, receiver, ctx);
    }

    public entry fun clear_empty_credential<S, R>(
        credential: Credential<S, R>,
        ctx: &mut TxContext,
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