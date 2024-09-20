// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMaverickV2RewardFactory} from "./IMaverickV2RewardFactory.sol";
import {IMaverickV2Reward} from "./IMaverickV2Reward.sol";
import {IMaverickV2VotingEscrow} from "./IMaverickV2VotingEscrow.sol";
import {IMaverickV2IncentiveMatcherCaller} from "./IMaverickV2IncentiveMatcherCaller.sol";

interface IMaverickV2IncentiveMatcher {
    error IncentiveMatcherInvalidEpoch(uint256 epoch);
    error IncentiveMatcherNotRewardFactoryContract(IMaverickV2Reward rewardContract);
    error IncentiveMatcherEpochHasNotEnded(uint256 currentTime, uint256 epochEnd);
    error IncentiveMatcherVotePeriodNotActive(uint256 currentTime, uint256 voteStart, uint256 voteEnd);
    error IncentiveMatcherVetoPeriodNotActive(uint256 currentTime, uint256 vetoStart, uint256 vetoEnd);
    error IncentiveMatcherVetoPeriodHasNotEnded(uint256 currentTime, uint256 voteEnd);
    error IncentiveMatcherSenderHasAlreadyVoted();
    error IncentiveMatcherSenderHasNoVotingPower(address voter, uint256 voteSnapshotTimestamp);
    error IncentiveMatcherInvalidTargetOrder(IMaverickV2Reward lastReward, IMaverickV2Reward voteReward);
    error IncentiveMatcherInvalidVote(
        IMaverickV2Reward rewardContract,
        uint256 voteWeights,
        uint256 totalVoteWeight,
        uint256 vote
    );
    error IncentiveMatcherEpochAlreadyDistributed(uint256 epoch, IMaverickV2Reward rewardContract);
    error IncentiveMatcherEpochHasEnded(uint256 epoch);
    error IncentiveMatcherRewardDoesNotHaveVeStakingOption();
    error IncentiveMatcherMatcherAlreadyVetoed(address matcher, IMaverickV2Reward rewardContract, uint256 epoch);
    error IncentiveMatcherMatcherHasNoBudget(address user, uint256 epoch);
    error IncentiveMatcherZeroAmount();
    error IncentiveMatcherRewardInvalidIncentiveToken(uint256 epoch, address matcher, IERC20 token);
    error IncentiveMatcherTokenMultipliersAlreadySet(uint256 epoch);
    error IncentiveMatcherNotPermissionedCaller(address caller, address permissionedCaller);

    event BudgetAdded(uint256 indexed epoch, address indexed matcher, uint256 matchAmount, uint256 voteAmount);
    event BudgetRolledOver(
        address indexed matcher,
        uint256 matchRolloverAmount,
        uint256 voteRolloverAmount,
        uint256 matchedEpoch,
        uint256 newEpoch
    );
    event IncentiveAdded(uint256 indexed epoch, IMaverickV2Reward indexed rewardContract, uint256 amount);
    event Vote(uint256 indexed epoch, address indexed voter, IMaverickV2Reward indexed rewardContract, uint256 vote);
    event Distribute(
        uint256 indexed epoch,
        IMaverickV2Reward indexed rewardContract,
        address indexed matcher,
        IERC20 _baseToken,
        uint256 totalMatch,
        uint256 voteMatch,
        uint256 incentiveMatch
    );
    event Veto(
        uint256 indexed epoch,
        address indexed matcher,
        IMaverickV2Reward indexed rewardContract,
        uint256 voteProductDeduction,
        uint256 externalIncentivesDeduction
    );
    event NonBaseTokenIncentiveAdded(
        uint256 indexed epoch,
        IMaverickV2Reward indexed rewardContract,
        uint256 amount,
        IERC20 token
    );
    event SetTokenMultipliers(uint256 indexed epoch, address indexed matcher, TokenMultiplier[] tokenMultipliers);
    event NonBaseTokenIncentiveApplied(
        uint256 indexed epoch,
        address indexed matcher,
        IMaverickV2Reward indexed rewardContract,
        uint256 nonBaseAmount,
        uint256 adjustedAmount,
        uint256 tokenMultiplierIndex,
        IERC20 token
    );

    struct TokenMultiplier {
        IERC20 token;
        uint256 multiplier;
    }

    struct MatchRewardData {
        uint128 nonBaseExternalIncentives;
        uint128 nonBaseVoteProduct;
        bool hasDistributed;
        bool hasVetoed;
        bool hasAccountedForNonBaseIncentives;
    }

    struct EpochInformation {
        uint128 votes;
        uint128 voteProduct;
        uint128 externalIncentives;
        bool tracked;
    }

    struct RewardData {
        IMaverickV2Reward rewardContract;
        EpochInformation rewardInformation;
    }

    struct MatcherData {
        uint128 matchBudget;
        uint128 voteBudget;
        uint128 externalIncentivesDeduction;
        uint128 voteProductDeduction;
        uint128 nonBaseExternalIncentives;
        uint128 nonBaseVoteProduct;
        TokenMultiplier[] tokenMultipliers;
    }

    struct NonBaseIncentives {
        IERC20 token;
        IMaverickV2Reward rewardContract;
        uint256 incentiveAmount;
    }

    /**
     * @notice This function retrieves checkpoint data for a specific epoch.
     * @param epoch The epoch for which to retrieve checkpoint data.
     * @return matchBudget The amount of match tokens budgeted for the epoch.
     * @return voteBudget The amount of vote tokens budgeted for the epoch.
     * @return epochTotals Struct with total votes, incentives, and pro rata product
     */
    function checkpointData(
        uint256 epoch
    ) external view returns (uint128 matchBudget, uint128 voteBudget, EpochInformation memory epochTotals);

    /**
     * @notice This function retrieves match budget checkpoint data for a specific epoch.
     * @param epoch The epoch for which to retrieve checkpoint data.
     * @param user Address of user who's budget to return.
     * @return matchBudget The amount of match tokens budgeted for the epoch by this user.
     * @return voteBudget The amount of vote tokens budgeted for the epoch by this user.
     */
    function checkpointMatcherBudget(
        uint256 epoch,
        address user
    ) external view returns (uint128 matchBudget, uint128 voteBudget);

    /**
     * @notice This function retrieves the nonBase incentives for a set of reward contracts.
     * @param epoch The epoch for which to retrieve checkpoint data.
     * @param tokens Incentive tokens to check.
     * @param rewardContracts Array of address of the reward contracts to check.
     * @return nonBaseIncentives Array of Structs of incentive information.  If
     * a given reward contract/token pair has no incentives, then there will be
     * no entry for that pair in the returned array.
     */
    function checkpointNonBaseIncentiveInfo(
        uint256 epoch,
        IERC20[] memory tokens,
        IMaverickV2Reward[] memory rewardContracts
    ) external view returns (NonBaseIncentives[] memory nonBaseIncentives);

    /**
     * @notice Returns data about a given matcher in an epoch.
     * @param epoch The epoch for which to retrieve checkpoint data.
     * @param matcher Address of matcher.
     * @return matcherData Bugdet and deductions amounts for the epoch/matcher.
     * The returned struct has a field for nonBaseExternalIncentives, but this
     * value only tracks the amount of non-base incentives have have been
     * "applied" such that a user called `applyNonBaseTokenMatch`.  Prior to
     * that, the amount of nonBase incentives is available through the
     * `checkpointNonBaseIncentiveInfo` view function.
     */
    function checkpointMatcherData(
        uint256 epoch,
        address matcher
    ) external view returns (MatcherData memory matcherData);

    /**
     * @notice This function retrieves checkpoint data for a specific reward contract within an epoch.
     * @param epoch The epoch for which to retrieve checkpoint data.
     * @param rewardContract The address of the reward contract.
     * @return rewardData Includes votesByReward - The total number of votes
     * cast for the reward contract in the epoch; and
     * externalIncentivesByReward - The total amount of external incentives
     * added for the reward contract in the epoch.
     */
    function checkpointRewardData(
        uint256 epoch,
        IMaverickV2Reward rewardContract
    ) external view returns (RewardData memory rewardData);

    /**
     * @notice Returns the count of activeRewards for a given epoch.
     */
    function activeRewardsCount(uint256 epoch) external view returns (uint256 count);

    /**
     * @notice Returns the count of budget matchers for a given epoch.
     */
    function matchersCount(uint256 epoch) external view returns (uint256 count);

    /**
     * @notice Returns paginated list of all matchers for an epoch between the
     * input indexes.
     * @param epoch The epoch for which to retrieve data.
     * @param startIndex The start index of the pagination.
     * @param endIndex The end index of the pagination.
     * @return returnElements Matcher addresses.
     * @return matcherData Struct of information about each matcher for this epoch.
     */
    function matchers(
        uint256 epoch,
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (address[] memory returnElements, MatcherData[] memory matcherData);

    /**
     * @notice This function retrieves checkpoint data for all active rewards
     * contracts.  User can paginate through the list by setting the input
     * index values.
     * @param epoch The epoch for which to retrieve checkpoint data.
     * @param startIndex The start index of the pagination.
     * @param endIndex The end index of the pagination.
     * @return returnElements For each active Rewards with incentives, includes
     * votesByReward - The total number of votes cast for the reward contract
     * in the epoch; and externalIncentivesByReward - The total amount of
     * external incentives added for the reward contract in the epoch.
     */
    function activeRewards(
        uint256 epoch,
        uint256 startIndex,
        uint256 endIndex
    ) external view returns (RewardData[] memory returnElements);

    /**
     * @notice View function that returns the amount of excess budget that cam be rolling over.
     * @param  epoch The epoch of the budget contribution.
     * @param  matcher Matcher address that added the match budget.
     * @return matchRolloverAmount The amount of match tokens that will be rolled over.
     * @return voteRolloverAmount The amount of vote tokens that will be rolled over.
     */
    function getRolloverBudget(
        uint256 epoch,
        address matcher
    ) external view returns (uint256 matchRolloverAmount, uint256 voteRolloverAmount);

    /**
     * @notice This function checks if a given epoch is valid.
     * @param epoch The epoch to check.
     * @return _isEpoch True if the epoch input is a valid epoch, False otherwise.
     */
    function isEpoch(uint256 epoch) external pure returns (bool _isEpoch);

    /**
     * @notice This function retrieves the number of the most recently completed epoch.
     * @return epoch The number of the last epoch.
     */
    function lastEpoch() external view returns (uint256 epoch);

    /**
     * @notice This function checks if a specific epoch has ended.
     * @param epoch The epoch to check.
     * @return isOver True if the epoch has ended, False otherwise.
     */
    function epochIsOver(uint256 epoch) external view returns (bool isOver);

    /**
     * @notice This function checks if the vetoing period is active for a specific epoch.
     * @param epoch The epoch to check.
     * @return isActive True if the vetoing period is active, False otherwise.
     */
    function vetoingIsActive(uint256 epoch) external view returns (bool isActive);

    /**
     * @notice This function checks if the voting period is active for a specific epoch.
     * @param epoch The epoch to check.
     * @return isActive True if the voting period is active, False otherwise.
     */
    function votingIsActive(uint256 epoch) external view returns (bool isActive);

    /**
     * @notice This function retrieves the current epoch number.
     * @return epoch The current epoch number.
     */
    function currentEpoch() external view returns (uint256 epoch);

    /**
     * @notice Returns the timestamp when voting starts.  This is also the
     * voting snapshot timestamp where the voting power for users is determined
     * for that epoch.
     * @param epoch The epoch to check.
     */
    function votingStart(uint256 epoch) external pure returns (uint256 start);

    /**
     * @notice This function checks if a specific reward contract has a veToken staking option.
     * @notice For a rewards contract to be eligible for matching, the rewards
     * contract must have the baseToken's ve contract as a locking option.
     * @param rewardContract The address of the reward contract.
     */
    function rewardHasVeCheck(IMaverickV2Reward rewardContract) external view;

    /**
     * @notice This function allows adding a new budget to the matcher contract.
     * @notice called by protocol to add base token budget to an epoch that
     * will be used for matching incentives.  Can be called anytime before or
     * during the epoch.
     * @param matchBudget The amount of match tokens to add.
     * @param voteBudget The amount of vote tokens to add.
     * @param epoch The epoch for which the budget is added.
     */
    function addMatchingBudget(uint128 matchBudget, uint128 voteBudget, uint256 epoch) external;

    /**
     * @notice This function allows adding a new incentive to the system.
     * @notice Called by protocol to add incentives to a given rewards contract.
     * @param rewardContract The address of the reward contract for the incentive.
     * @param amount The total amount of the incentive.
     * @param _duration The desired duration (in seconds) for which this incentive will be active.
     * @return duration The actual duration (in seconds) for which this incentive will be active.
     */
    function addIncentives(
        IMaverickV2Reward rewardContract,
        uint128 amount,
        uint256 _duration
    ) external returns (uint256 duration);

    /**
     * @notice This function allows adding a new incentive to the system.
     * @notice Called by the permissioned caller to add incentives to a given
     * rewards contract.
     * @param rewardContract The address of the reward contract for the incentive.
     * @param amount The total amount of the incentive.
     * @param token The token that the user will incentivize with.
     */
    function permissionedAddIncentives(IMaverickV2Reward rewardContract, uint128 amount, IERC20 token) external;

    /**
     * @notice This function allows adding a new incentive in a non base token.
     * @notice Called by protocol to add incentives to a given rewards contract.
     * @param rewardContract The address of the reward contract for the incentive.
     * @param amount The total amount of the incentive.
     * @param _duration The desired duration (in seconds) for which this incentive will be active.
     * @param token The token that the user will incentivize with.
     * @return duration The actual duration (in seconds) for which this incentive will be active.
     */
    function addNonBaseTokenIncentives(
        IMaverickV2Reward rewardContract,
        uint128 amount,
        uint256 _duration,
        IERC20 token
    ) external returns (uint256 duration);

    /**
     * @notice This function is available after the epoch ends and before any
     * vetos are applied. This function applies a matcher's non-base token
     * multiplier to non-base token incentives.
     * @param rewardContract The address of the reward contract for the incentive.
     * @param matcher The address of the matcher whose budget is getting distributed.
     * @param tokenMultiplierIndex The index of the
     * `checkpointMultipliers` struct corresponding to the desired token.
     * @param epoch The epoch for which to apply non-base multiplier.
     * @return  adjustedAmount The amount of base token credited to the matching accounting.
     */
    function applyNonBaseTokenMatch(
        IMaverickV2Reward rewardContract,
        address matcher,
        uint256 tokenMultiplierIndex,
        uint256 epoch
    ) external returns (uint128 adjustedAmount);

    /**
     * @notice This function sets the non-base token multipliers for a given
     * epoch where the calling address is the budget matcher.  Each matcher can
     * have their own set of unique multipliers.
     * @param _tokenMultipliers Array of (token,multiplier) structs.
     * @param epoch The epoch for which the budget is added.
     */
    function setTokenMultipliers(TokenMultiplier[] memory _tokenMultipliers, uint256 epoch) external;

    /**
     * @notice This function allows a user to cast a vote for specific reward contracts.
     * @notice Called by ve token holders to vote for rewards contracts in a
     * given epoch.  voteTargets have to be passed in ascending sort order as a
     * unique set of values. weights are relative values that are scales by the
     * user's voting power.
     * @param voteTargets An array of addresses for the reward contracts to vote for.
     * @param weights An array of weights for each vote target.
     */
    function vote(IMaverickV2Reward[] memory voteTargets, uint256[] memory weights) external;

    /**
     * @notice This function allows casting a veto on a specific reward contract for an epoch.
     * @notice Veto a given rewards contract.  If a rewards contract is vetoed,
     * it will not receive any matching incentives.  Rewards contracts can only
     * be vetoed in the VETO_PERIOD seconds after the end of the epoch.
     * @param rewardContract The address of the reward contract to veto.
     */
    function veto(
        IMaverickV2Reward rewardContract
    ) external returns (uint128 voteProductDeduction, uint128 externalIncentivesDeduction);

    /**
     * @notice This function allows distributing incentives for a specific reward contract in a particular epoch.
     * @notice Called by any user to distribute matching incentives to a given
     * reward contract for a given epoch.  Call is only functional after the
     * vetoing period for the epoch is over.
     * @param rewardContract The address of the reward contract to distribute incentives for.
     * @param matcher The address of the matcher whose budget is getting distributed.
     * @param epoch The epoch for which to distribute incentives.
     * @return totalMatch Total amount of matching tokens distributed.
     * @return incentiveMatch Amount of match from incentive matching.
     * @return voteMatch Amount of match from vote matching.
     */
    function distribute(
        IMaverickV2Reward rewardContract,
        address matcher,
        uint256 epoch
    ) external returns (uint256 totalMatch, uint256 incentiveMatch, uint256 voteMatch);

    /**
     * @notice This function allows rolling over excess budget from a previous
     * epoch to a new epoch.
     * @dev Excess vote match budget amounts that have not been distributed
     * will not rollover and will become permanently locked.  To avoid this, a
     * matcher should call distribute on all rewards contracts before calling
     * rollover.
     * @param matchedEpoch The epoch from which to roll over the budget.
     * @param newEpoch The epoch to which to roll over the budget.
     * @return matchRolloverAmount The amount of match tokens rolled over.
     * @return voteRolloverAmount The amount of vote tokens rolled over.
     */
    function rolloverExcessBudget(
        uint256 matchedEpoch,
        uint256 newEpoch
    ) external returns (uint256 matchRolloverAmount, uint256 voteRolloverAmount);

    /**
     * @notice This function retrieves the epoch period length.
     */
    // solhint-disable-next-line func-name-mixedcase
    function EPOCH_PERIOD() external view returns (uint256);

    /**
     * @notice This function retrieves the period length of the epoch before
     * voting starts.  After an epoch begins, there is a window of time where
     * voting is not possible which is the value this function returns.
     */
    // solhint-disable-next-line func-name-mixedcase
    function PRE_VOTE_PERIOD() external view returns (uint256);

    /**
     * @notice This function retrieves the vetoing period length.
     */
    // solhint-disable-next-line func-name-mixedcase
    function VETO_PERIOD() external view returns (uint256);

    /**
     * @notice The function retrieves the notify period length, which is the
     * amount of time in seconds during which the matching reward will be
     * distributed through the rewards contract.
     */
    // solhint-disable-next-line func-name-mixedcase
    function NOTIFY_PERIOD() external view returns (uint256);

    /**
     * @notice Permissioned caller address that can call the
     * permissionedAddIncentives function.  This value is set by the
     * IncentiveMatcherFactory on deploy.
     */
    function permissionedCaller() external view returns (IMaverickV2IncentiveMatcherCaller);

    /**
     * @notice This function retrieves the base token used by the IncentiveMatcher contract.
     * @return The address of the base token.
     */
    function baseToken() external view returns (IERC20);

    /**
     * @notice This function retrieves the address of the MaverickV2RewardFactory contract.
     * @return The address of the MaverickV2RewardFactory contract.
     */
    function rewardFactory() external view returns (IMaverickV2RewardFactory);

    /**
     * @notice This function retrieves the address of the veToken contract.
     * @return The address of the veToken contract.
     */
    function veToken() external view returns (IMaverickV2VotingEscrow);

    /**
     * @notice This function checks if a specific user has voted in a particular epoch.
     * @param user The address of the user.
     * @param epoch The epoch to check.
     * @return True if the user has voted, False otherwise.
     */
    function hasVoted(address user, uint256 epoch) external view returns (bool);

    /**
     * @notice This function checks if a specific matcher has cast a veto on a reward contract for an epoch.
     * @param matcher The address of the IncentiveMatcher contract.
     * @param rewardContract The address of the reward contract.
     * @param epoch The epoch to check.
     * @return True if the matcher has cast a veto, False otherwise.
     */
    function hasVetoed(address matcher, IMaverickV2Reward rewardContract, uint256 epoch) external view returns (bool);

    /**
     * @notice This function checks if incentives have been distributed for a specific reward contract in an epoch.
     * @param matcher The address of the IncentiveMatcher contract.
     * @param rewardContract The address of the reward contract.
     * @param epoch The epoch to check.
     * @return True if incentives have been distributed, False otherwise.
     */
    function hasDistributed(
        address matcher,
        IMaverickV2Reward rewardContract,
        uint256 epoch
    ) external view returns (bool);

    /**
     * @notice This function calculates the end timestamp for a specific epoch.
     * @param epoch The epoch for which to calculate the end timestamp.
     * @return end The end timestamp of the epoch.
     */
    function epochEnd(uint256 epoch) external pure returns (uint256 end);

    /**
     * @notice This function calculates the end timestamp for the vetoing period of a specific epoch.
     * @param epoch The epoch for which to calculate the vetoing period end timestamp.
     * @return end The end timestamp of the vetoing period for the epoch.
     */
    function vetoingEnd(uint256 epoch) external pure returns (uint256 end);

    /**
     * @notice This function checks if the vetoing period is over for a specific epoch.
     * @param epoch The epoch to check.
     * @return isOver True if the vetoing period has ended for the given epoch, False otherwise.
     */
    function vetoingIsOver(uint256 epoch) external view returns (bool isOver);
}
