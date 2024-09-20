// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast as Cast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math as OzMath} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Math} from "@maverick/v2-common/contracts/libraries/Math.sol";
import {Multicall} from "@maverick/v2-common/contracts/base/Multicall.sol";

import {IMaverickV2Reward} from "./interfaces/IMaverickV2Reward.sol";
import {IMaverickV2IncentiveMatcher} from "./interfaces/IMaverickV2IncentiveMatcher.sol";
import {IMaverickV2IncentiveMatcherCaller} from "./interfaces/IMaverickV2IncentiveMatcherCaller.sol";
import {IMaverickV2VotingEscrow} from "./interfaces/IMaverickV2VotingEscrow.sol";
import {IMaverickV2IncentiveMatcherFactory} from "./interfaces/IMaverickV2IncentiveMatcherFactory.sol";
import {IMaverickV2RewardFactory} from "./interfaces/IMaverickV2RewardFactory.sol";

/**
 * @notice IncentiveMatcher contract corresponds to a ve token and manages
 * incentive matching for incentives related to that ve token.  This contract
 * allows protocols to provide matching incentives to Maverick Reward Contracts
 * and allows ve holders to vote their token to increase the match in a Reward
 * Contract.  Reward contracts are typically staked with a Boosted Position
 * (BP) token, but the Reward contracts can be staked with any ERC-20 token.
 *
 * IncentiveMatcher has a concept of a matching epoch and the following actors:
 *
 * - BP incentive adder
 * - Matching budget adder
 * - Voter
 *
 * @notice The lifecycle of an epoch is as follows:
 *
 * - Anytime before or during an epoch, any party can permissionlessly add a
 * matching and/or voting incentive budget to an epoch.  These incentives will
 * boost incentives added to any BPs during the epoch.
 * - During the epoch any party can permissionlessly add incentives to BPs.
 * These incentives are eligible to be boosted through matching and voting.
 * - During the voting portion of the epoch, any ve holder can cast their ve
 * vote for eligible BPs.
 * - At the end of the epoch, there is a vetoing period where any user who
 * provided matching incentive budget can choose to veto a BP from being
 * matched by their portion of the matching budget.
 * - At the end of the vetoing period, the matching rewards are eligible for
 * distribution.  Any user can permissionlessly call `distribute` for a given
 * BP and epoch.  This call will compute the matching boost for the BP and then
 * send the BP reward contract the matching amount, which will in turn
 * distribute the reward to the BP LPs.
 *
 * @notice Budget matchers can choose to match both the reward contract's base
 * token as well as other "non-base tokens" the rewards contract supports.  For
 * non-base tokens, the matcher who added the budget will need to specify a
 * rate or "multiplier" that converts a given amount of non-base tokens to an
 * amount of base tokens.  During the veto period, any user can call a function
 * to apply this match to the non-base token incentives thereby ensure those
 * incentives are matched.
 */
contract MaverickV2IncentiveMatcher is IMaverickV2IncentiveMatcher, ReentrancyGuard, Multicall {
    using Cast for uint256;
    using SafeERC20 for IERC20;

    /// @inheritdoc IMaverickV2IncentiveMatcher
    uint256 public constant EPOCH_PERIOD = 14 days;
    /// @inheritdoc IMaverickV2IncentiveMatcher
    uint256 public constant PRE_VOTE_PERIOD = 7 days;
    /// @inheritdoc IMaverickV2IncentiveMatcher
    uint256 public constant VETO_PERIOD = 2 days;

    /// @inheritdoc IMaverickV2IncentiveMatcher
    uint256 public constant NOTIFY_PERIOD = 14 days;

    /// @inheritdoc IMaverickV2IncentiveMatcher
    IERC20 public immutable baseToken;
    /// @inheritdoc IMaverickV2IncentiveMatcher
    IMaverickV2RewardFactory public immutable rewardFactory;
    /// @inheritdoc IMaverickV2IncentiveMatcher
    IMaverickV2VotingEscrow public immutable veToken;
    /// @inheritdoc IMaverickV2IncentiveMatcher
    IMaverickV2IncentiveMatcherCaller public immutable permissionedCaller;

    // checkpoints indexed by epoch start: time % EPOCH_PERIOD
    mapping(uint256 epoch => CheckpointData) private checkpoints;

    // data per epoch
    struct CheckpointData {
        // accumulator for matchbudget of this epoch
        uint128 matchBudget;
        // accumulator for votebudget of this epoch
        uint128 voteBudget;
        // totals for vote product, votes, and incentives added
        EpochInformation dataTotals;
        // per contract data for vote product, votes, and incentives added
        mapping(IMaverickV2Reward => EpochInformation) dataByReward;
        // amount that each matcher has sent as budget for an epoch and tracking of veto deductions
        mapping(address matcher => MatcherData) matcherData;
        // array of rewards active that have external incentives this epoch
        IMaverickV2Reward[] activeRewards;
        // array of addresses that have provided matching budget
        address[] matchers;
        // tracks whether a matcher hasDistributed and hasVetoed this epoch
        mapping(address matcher => mapping(IMaverickV2Reward reward => MatchRewardData)) matchReward;
        // tracks whether user has voted this epoch
        mapping(address voter => bool) hasVoted;
        // tracks non-base token amounts
        mapping(IERC20 token => mapping(IMaverickV2Reward reward => uint128)) nonBaseTokenExternalIncentive;
    }

    constructor() {
        (baseToken, veToken, rewardFactory) = IMaverickV2IncentiveMatcherFactory(msg.sender)
            .incentiveMatcherParameters();
        permissionedCaller = IMaverickV2IncentiveMatcherFactory(msg.sender).permissionedCaller();
    }

    /////////////////////////////////////
    /// Epoch Checkers and Helpers
    /////////////////////////////////////

    modifier checkEpoch(uint256 epoch) {
        if (!isEpoch(epoch)) revert IncentiveMatcherInvalidEpoch(epoch);
        _;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function checkpointMatcherBudget(
        uint256 epoch,
        address matcher
    ) public view checkEpoch(epoch) returns (uint128 matchBudget, uint128 voteBudget) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        MatcherData storage matcherData = checkpoint.matcherData[matcher];

        (matchBudget, voteBudget) = (matcherData.matchBudget, matcherData.voteBudget);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function checkpointMatcherData(
        uint256 epoch,
        address matcher
    ) public view checkEpoch(epoch) returns (MatcherData memory matcherData) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        matcherData = checkpoint.matcherData[matcher];
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function checkpointRewardData(
        uint256 epoch,
        IMaverickV2Reward rewardContract
    ) public view checkEpoch(epoch) returns (RewardData memory rewardData) {
        rewardData.rewardInformation = checkpoints[epoch].dataByReward[rewardContract];
        rewardData.rewardContract = rewardContract;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function checkpointNonBaseIncentiveInfo(
        uint256 epoch,
        IERC20[] memory tokens,
        IMaverickV2Reward[] memory rewardContracts
    ) public view checkEpoch(epoch) returns (NonBaseIncentives[] memory nonBaseIncentives) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        nonBaseIncentives = new NonBaseIncentives[](rewardContracts.length * tokens.length);
        uint256 count;
        for (uint256 t; t < tokens.length; t++) {
            for (uint256 r; r < rewardContracts.length; r++) {
                uint256 amount = checkpoint.nonBaseTokenExternalIncentive[tokens[t]][rewardContracts[r]];
                if (amount != 0) {
                    nonBaseIncentives[count] = NonBaseIncentives(tokens[t], rewardContracts[r], amount);
                    count++;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(nonBaseIncentives, count)
        }
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function activeRewardsCount(uint256 epoch) public view checkEpoch(epoch) returns (uint256 count) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        count = checkpoint.activeRewards.length;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function activeRewards(
        uint256 epoch,
        uint256 startIndex,
        uint256 endIndex
    ) public view checkEpoch(epoch) returns (RewardData[] memory returnElements) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        endIndex = Math.min(checkpoint.activeRewards.length, endIndex);
        returnElements = new RewardData[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            returnElements[i - startIndex] = checkpointRewardData(epoch, checkpoint.activeRewards[i]);
        }
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function matchersCount(uint256 epoch) public view checkEpoch(epoch) returns (uint256 count) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        count = checkpoint.matchers.length;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function matchers(
        uint256 epoch,
        uint256 startIndex,
        uint256 endIndex
    ) public view checkEpoch(epoch) returns (address[] memory returnElements, MatcherData[] memory matcherData) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        endIndex = Math.min(checkpoint.matchers.length, endIndex);
        returnElements = new address[](endIndex - startIndex);
        matcherData = new MatcherData[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            returnElements[i - startIndex] = checkpoint.matchers[i];
            matcherData[i - startIndex] = checkpointMatcherData(epoch, returnElements[i - startIndex]);
        }
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function checkpointData(
        uint256 epoch
    )
        public
        view
        checkEpoch(epoch)
        returns (uint128 matchBudget, uint128 voteBudget, EpochInformation memory epochTotals)
    {
        CheckpointData storage checkpoint = checkpoints[epoch];

        (matchBudget, voteBudget, epochTotals) = (checkpoint.matchBudget, checkpoint.voteBudget, checkpoint.dataTotals);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function hasVoted(address user, uint256 epoch) public view checkEpoch(epoch) returns (bool) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        return checkpoint.hasVoted[user];
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function hasVetoed(address matcher, IMaverickV2Reward rewardContract, uint256 epoch) public view returns (bool) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        MatchRewardData storage matchReward = checkpoint.matchReward[matcher][rewardContract];
        return matchReward.hasVetoed;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function hasDistributed(
        address matcher,
        IMaverickV2Reward rewardContract,
        uint256 epoch
    ) public view returns (bool) {
        CheckpointData storage checkpoint = checkpoints[epoch];
        MatchRewardData storage matchReward = checkpoint.matchReward[matcher][rewardContract];
        return matchReward.hasDistributed;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function isEpoch(uint256 epoch) public pure returns (bool _isEpoch) {
        _isEpoch = epoch % EPOCH_PERIOD == 0;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function epochIsOver(uint256 epoch) public view returns (bool isOver) {
        isOver = block.timestamp >= epochEnd(epoch);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function vetoingIsActive(uint256 epoch) public view returns (bool isActive) {
        // veto period is `epoch + EPOCH_PERIOD` to `epoch + EPOCH_PERIOD +
        // VETO_PERIOD
        isActive = epochIsOver(epoch) && block.timestamp < vetoingEnd(epoch);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function votingIsActive(uint256 epoch) public view returns (bool isActive) {
        // vote period is `epoch + PRE_VOTE_PERIOD` to `epoch + EPOCH_PERIOD
        isActive = block.timestamp >= votingStart(epoch) && block.timestamp < epochEnd(epoch);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function vetoingIsOver(uint256 epoch) public view returns (bool isOver) {
        isOver = block.timestamp >= vetoingEnd(epoch);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function votingStart(uint256 epoch) public pure returns (uint256 start) {
        start = epoch + PRE_VOTE_PERIOD;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function epochEnd(uint256 epoch) public pure returns (uint256 end) {
        end = epoch + EPOCH_PERIOD;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function vetoingEnd(uint256 epoch) public pure returns (uint256 end) {
        end = epochEnd(epoch) + VETO_PERIOD;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function currentEpoch() public view returns (uint256 epoch) {
        epoch = (block.timestamp / EPOCH_PERIOD) * EPOCH_PERIOD;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function lastEpoch() public view returns (uint256 epoch) {
        epoch = currentEpoch() - EPOCH_PERIOD;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function rewardHasVeCheck(IMaverickV2Reward rewardContract) public view {
        uint8 index = rewardContract.tokenIndex(baseToken);
        // only need to check address zero as reward contract is a factory
        // contract and the factory ensures that any non-zero ve contract is
        // the ve contract for the base token
        if (address(rewardContract.veTokenByIndex(index)) == address(0))
            revert IncentiveMatcherRewardDoesNotHaveVeStakingOption();
    }

    /////////////////////////////////////
    /// User Actions
    /////////////////////////////////////

    function _addBudget(uint128 matchBudget, uint128 voteBudget, uint256 epoch) private {
        uint256 totalMatch = matchBudget + voteBudget;
        if (totalMatch == 0) revert IncentiveMatcherZeroAmount();

        if (epochIsOver(epoch)) revert IncentiveMatcherEpochHasEnded(epoch);
        CheckpointData storage checkpoint = checkpoints[epoch];

        // track budget totals
        checkpoint.matchBudget += matchBudget;
        checkpoint.voteBudget += voteBudget;

        MatcherData storage matcherData = checkpoint.matcherData[msg.sender];

        // add matcher to list
        if (matcherData.matchBudget == 0 && matcherData.voteBudget == 0) checkpoint.matchers.push(msg.sender);

        // increment budget for this matcher
        matcherData.matchBudget += matchBudget;
        matcherData.voteBudget += voteBudget;
        emit BudgetAdded(epoch, msg.sender, matchBudget, voteBudget);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function addMatchingBudget(
        uint128 matchBudget,
        uint128 voteBudget,
        uint256 epoch
    ) public checkEpoch(epoch) nonReentrant {
        _addBudget(matchBudget, voteBudget, epoch);
        uint256 totalMatch = matchBudget + voteBudget;
        baseToken.safeTransferFrom(msg.sender, address(this), totalMatch);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function setTokenMultipliers(
        TokenMultiplier[] memory _tokenMultipliers,
        uint256 epoch
    ) public checkEpoch(epoch) nonReentrant {
        if (epochIsOver(epoch)) revert IncentiveMatcherEpochHasEnded(epoch);
        MatcherData storage matchData = checkpoints[epoch].matcherData[msg.sender];
        if (matchData.tokenMultipliers.length != 0) revert IncentiveMatcherTokenMultipliersAlreadySet(epoch);

        for (uint256 k; k < _tokenMultipliers.length; k++) {
            matchData.tokenMultipliers.push(_tokenMultipliers[k]);
        }
        emit SetTokenMultipliers(epoch, msg.sender, _tokenMultipliers);
    }

    function _addBaseIncentives(IMaverickV2Reward rewardContract, uint128 amount) internal {
        // check reward is factory
        if (!rewardFactory.isFactoryContract(rewardContract))
            revert IncentiveMatcherNotRewardFactoryContract(rewardContract);
        rewardHasVeCheck(rewardContract);
        if (amount == 0) revert IncentiveMatcherZeroAmount();

        uint256 epoch = currentEpoch();

        CheckpointData storage checkpoint = checkpoints[epoch];

        EpochInformation storage rewardTotals = checkpoint.dataTotals;
        EpochInformation storage rewardValues = checkpoint.dataByReward[rewardContract];

        if (!rewardValues.tracked) checkpoint.activeRewards.push(rewardContract);
        rewardValues.tracked = true;

        uint128 existing = rewardValues.externalIncentives;
        rewardValues.externalIncentives = existing + amount;
        rewardTotals.externalIncentives += amount;

        _updateVoteProducts(rewardValues, rewardTotals);
        emit IncentiveAdded(epoch, rewardContract, amount);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function addIncentives(
        IMaverickV2Reward rewardContract,
        uint128 amount,
        uint256 _duration
    ) public nonReentrant returns (uint256 duration) {
        _addBaseIncentives(rewardContract, amount);

        baseToken.safeTransferFrom(msg.sender, address(rewardContract), amount);
        duration = rewardContract.notifyRewardAmount(baseToken, _duration);
    }

    function _addNonBaseIncentives(IMaverickV2Reward rewardContract, uint128 amount, IERC20 token) internal {
        // check reward is factory
        if (!rewardFactory.isFactoryContract(rewardContract))
            revert IncentiveMatcherNotRewardFactoryContract(rewardContract);
        rewardHasVeCheck(rewardContract);
        if (amount == 0) revert IncentiveMatcherZeroAmount();

        uint256 epoch = currentEpoch();

        CheckpointData storage checkpoint = checkpoints[epoch];

        EpochInformation storage rewardValues = checkpoint.dataByReward[rewardContract];
        if (!rewardValues.tracked) checkpoint.activeRewards.push(rewardContract);
        rewardValues.tracked = true;

        uint128 existing = checkpoint.nonBaseTokenExternalIncentive[token][rewardContract];
        checkpoint.nonBaseTokenExternalIncentive[token][rewardContract] = existing + amount;

        emit NonBaseTokenIncentiveAdded(epoch, rewardContract, amount, token);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function addNonBaseTokenIncentives(
        IMaverickV2Reward rewardContract,
        uint128 amount,
        uint256 _duration,
        IERC20 token
    ) public nonReentrant returns (uint256 duration) {
        _addNonBaseIncentives(rewardContract, amount, token);

        token.safeTransferFrom(msg.sender, address(rewardContract), amount);
        // reverts if token is not valid for reward contract
        duration = rewardContract.notifyRewardAmount(token, _duration);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function permissionedAddIncentives(IMaverickV2Reward rewardContract, uint128 amount, IERC20 token) public {
        if (msg.sender != address(permissionedCaller))
            revert IncentiveMatcherNotPermissionedCaller(msg.sender, address(permissionedCaller));

        if (token == baseToken) {
            _addBaseIncentives(rewardContract, amount);
        } else {
            _addNonBaseIncentives(rewardContract, amount, token);
        }
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function applyNonBaseTokenMatch(
        IMaverickV2Reward rewardContract,
        address matcher,
        uint256 tokenMultiplierIndex,
        uint256 epoch
    ) public nonReentrant checkEpoch(epoch) returns (uint128 adjustedAmount) {
        if (!epochIsOver(epoch)) revert IncentiveMatcherEpochHasNotEnded(block.timestamp, epochEnd(epoch));

        CheckpointData storage checkpoint = checkpoints[epoch];
        MatchRewardData storage matchReward = checkpoint.matchReward[matcher][rewardContract];

        if (matchReward.hasVetoed) revert IncentiveMatcherMatcherAlreadyVetoed(matcher, rewardContract, epoch);
        if (matchReward.hasDistributed) revert IncentiveMatcherEpochAlreadyDistributed(epoch, rewardContract);

        // get multiplier
        TokenMultiplier memory tokenMultiplier = checkpoint.matcherData[matcher].tokenMultipliers[tokenMultiplierIndex];
        // zero multiplier indicates that this matcher is not matching this token
        if (tokenMultiplier.multiplier == 0)
            revert IncentiveMatcherRewardInvalidIncentiveToken(epoch, matcher, tokenMultiplier.token);

        // retrieve the nonBase amount and scale it by the multiplier
        uint128 nonBaseAmount = checkpoint.nonBaseTokenExternalIncentive[tokenMultiplier.token][rewardContract];
        // zero amount indicates there was no incentives from this token added
        if (nonBaseAmount == 0) revert IncentiveMatcherZeroAmount();

        MatcherData storage matcherData = checkpoint.matcherData[matcher];
        if (matcherData.voteBudget == 0 && matcherData.matchBudget == 0)
            revert IncentiveMatcherMatcherHasNoBudget(matcher, epoch);

        adjustedAmount = Math.mulDown(nonBaseAmount, tokenMultiplier.multiplier).toUint128();

        {
            // update incentive amounts with credit for the non-base token
            EpochInformation storage rewardValues = checkpoint.dataByReward[rewardContract];
            EpochInformation storage rewardTotals = checkpoint.dataTotals;

            // matcherData has totals
            matcherData.nonBaseExternalIncentives += adjustedAmount;
            // matchReward has per-reward amounts
            matchReward.nonBaseExternalIncentives += adjustedAmount;

            // votes * (base incentive + non base incentives)
            uint128 voteProduct_ = Math
                .mulDown(rewardValues.externalIncentives + matchReward.nonBaseExternalIncentives, rewardValues.votes)
                .toUint128();

            // subtract old value and add new value
            matcherData.nonBaseVoteProduct =
                Math.max128(rewardTotals.voteProduct, matcherData.nonBaseVoteProduct) -
                Math.max128(matchReward.nonBaseVoteProduct, rewardValues.voteProduct) +
                voteProduct_;

            // matchReward has reward/matcher accounting
            matchReward.nonBaseVoteProduct = voteProduct_;
        }

        emit NonBaseTokenIncentiveApplied(
            epoch,
            matcher,
            rewardContract,
            nonBaseAmount,
            adjustedAmount,
            tokenMultiplierIndex,
            tokenMultiplier.token
        );
    }

    function _inVetoPeriodCheck(uint256 epoch) internal view {
        // check vote period is over
        if (!vetoingIsActive(epoch)) {
            revert IncentiveMatcherVetoPeriodNotActive(block.timestamp, epochEnd(epoch), vetoingEnd(epoch));
        }
    }

    function _inVotePeriodCheck(uint256 epoch) internal view {
        if (!votingIsActive(epoch)) {
            revert IncentiveMatcherVotePeriodNotActive(block.timestamp, votingStart(epoch), epochEnd(epoch));
        }
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function vote(IMaverickV2Reward[] memory voteTargets, uint256[] memory weights) external nonReentrant {
        uint256 epoch = currentEpoch();
        _inVotePeriodCheck(epoch);

        CheckpointData storage checkpoint = checkpoints[epoch];
        if (checkpoint.hasVoted[msg.sender]) revert IncentiveMatcherSenderHasAlreadyVoted();
        checkpoint.hasVoted[msg.sender] = true;

        // we know voting is active at this point
        uint256 votingPower;

        // get voting power of sender; includes any voting power delegated to
        // this sender; voting power is ve pro rata as beginning of vote
        // period
        uint256 startTimestamp = votingStart(epoch);
        votingPower = Math.divFloor(
            veToken.getPastVotes(msg.sender, startTimestamp),
            veToken.getPastTotalSupply(startTimestamp)
        );

        if (votingPower == 0) revert IncentiveMatcherSenderHasNoVotingPower(msg.sender, votingStart(epoch));

        // compute total of relative weights user passed in
        uint256 totalVoteWeight;
        for (uint256 i; i < weights.length; i++) {
            totalVoteWeight += weights[i];
        }

        // vote targets have to be sorted; start with zero so we can check sort
        IMaverickV2Reward lastReward = IMaverickV2Reward(address(0));
        for (uint256 i; i < weights.length; i++) {
            IMaverickV2Reward rewardContract = voteTargets[i];
            // ensure addresses are unique and sorted
            if (rewardContract <= lastReward) revert IncentiveMatcherInvalidTargetOrder(lastReward, rewardContract);
            lastReward = rewardContract;

            // no need to check if factory reward because we check that in the
            // addIncentives call; a user can vote for a non-factory address
            // and that vote will essentially be a wasted vote. users can view
            // the elegible rewards contracts with a view call before they vote
            // to enusre they are voting on a active rewardcontract

            // translate relative vote weights into votes
            uint128 _vote = OzMath.mulDiv(weights[i], votingPower, totalVoteWeight).toUint128();
            if (_vote == 0) revert IncentiveMatcherInvalidVote(rewardContract, weights[i], totalVoteWeight, _vote);

            EpochInformation storage rewardValues = checkpoint.dataByReward[rewardContract];
            EpochInformation storage rewardTotals = checkpoint.dataTotals;

            rewardValues.votes += _vote;
            rewardTotals.votes += _vote;

            _updateVoteProducts(rewardValues, rewardTotals);

            emit Vote(epoch, msg.sender, rewardContract, _vote);
        }
    }

    /**
     * @notice The vote budget allocation is distributed pro rata of a "weight"
     * that is assigned to each reward contract.  The weight is the product of
     * the incentive addition and vote, or `W_i = E_i * V_i`, where E_i is the
     * external incentives for the ith contract, V_i is the vote for the ith
     * contract.
     *
     * @notice As either the external incentives or vote amounts change, this
     * function must be called in order to track both the sum weight,
     * sum W_i, and the individual weights, W_i.  To do this efficiently, this
     * matcher contract tracks both the sum weight and the individual
     * weight value for each contract.  When there is an update to either the
     * vote or external incentives, this function subtracts the current
     * contract weight value from the sum and adds the new weight value.
     */
    function _updateVoteProducts(
        EpochInformation storage rewardValues,
        EpochInformation storage rewardTotals
    ) internal {
        // if the vote elements in the pro rata computation are zero, this is a no-op function
        if (rewardTotals.externalIncentives == 0 || rewardTotals.votes == 0 || rewardValues.votes == 0) return;
        // need to track pro rata incentive product and the sum product.
        uint128 voteProduct_ = Math.mulDown(rewardValues.externalIncentives, rewardValues.votes).toUint128();

        rewardTotals.voteProduct = rewardTotals.voteProduct - rewardValues.voteProduct + voteProduct_;
        rewardValues.voteProduct = voteProduct_;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function veto(
        IMaverickV2Reward rewardContract
    ) public nonReentrant returns (uint128 voteProductDeduction, uint128 externalIncentivesDeduction) {
        uint256 epoch = lastEpoch();
        _inVetoPeriodCheck(epoch);

        CheckpointData storage checkpoint = checkpoints[epoch];
        MatchRewardData storage matchReward = checkpoint.matchReward[msg.sender][rewardContract];
        if (matchReward.hasVetoed) revert IncentiveMatcherMatcherAlreadyVetoed(msg.sender, rewardContract, epoch);
        matchReward.hasVetoed = true;

        MatcherData storage matcherData = checkpoint.matcherData[msg.sender];
        if (matcherData.voteBudget == 0 && matcherData.matchBudget == 0)
            revert IncentiveMatcherMatcherHasNoBudget(msg.sender, epoch);

        EpochInformation storage rewardValues = checkpoint.dataByReward[rewardContract];

        // if there is non-base token incentives, the non-base vote product
        // amount supercedes the base token voteProduct accounting, if not,
        // then the non-base value will be zero, so the max is used to decided
        // which value to apply as the deduction.
        voteProductDeduction = Math.max128(rewardValues.voteProduct, matchReward.nonBaseVoteProduct);
        matcherData.voteProductDeduction += voteProductDeduction;

        externalIncentivesDeduction = rewardValues.externalIncentives + matchReward.nonBaseExternalIncentives;
        matcherData.externalIncentivesDeduction += externalIncentivesDeduction;

        emit Veto(epoch, msg.sender, rewardContract, voteProductDeduction, externalIncentivesDeduction);
    }

    function _checkVetoPeriodEnded(uint256 epoch) internal view {
        if (!vetoingIsOver(epoch)) revert IncentiveMatcherVetoPeriodHasNotEnded(block.timestamp, vetoingEnd(epoch));
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function distribute(
        IMaverickV2Reward rewardContract,
        address matcher,
        uint256 epoch
    ) public checkEpoch(epoch) nonReentrant returns (uint256 totalMatch, uint256 incentiveMatch, uint256 voteMatch) {
        _checkVetoPeriodEnded(epoch);
        CheckpointData storage checkpoint = checkpoints[epoch];
        MatchRewardData storage matchReward = checkpoint.matchReward[matcher][rewardContract];

        if (matchReward.hasDistributed) revert IncentiveMatcherEpochAlreadyDistributed(epoch, rewardContract);
        matchReward.hasDistributed = true;

        if (!matchReward.hasVetoed) {
            // only need to compute matches for non-vetoed contracts
            EpochInformation storage rewardTotals = checkpoint.dataTotals;
            EpochInformation storage rewardValues = checkpoint.dataByReward[rewardContract];
            MatcherData storage matcherData = checkpoint.matcherData[matcher];

            // subtract the vetoed amount of incentives
            uint256 adjustedRewardIncentives = (rewardTotals.externalIncentives +
                matcherData.nonBaseExternalIncentives) - matcherData.externalIncentivesDeduction;

            if (adjustedRewardIncentives > 0) {
                uint256 externalIncentives = rewardValues.externalIncentives + matchReward.nonBaseExternalIncentives;

                // compute how much this reward gets matched;
                // need to check if we have enough for full match or if we have to pro rate
                uint256 matchBudget = matcherData.matchBudget;
                if (matchBudget >= adjustedRewardIncentives) {
                    // straight match
                    incentiveMatch = externalIncentives;
                } else {
                    // pro rate the match,
                    incentiveMatch = OzMath.mulDiv(matchBudget, externalIncentives, adjustedRewardIncentives);
                }
            }

            // subtract the vote deduction.  if there are non-base incentives,
            // then the matcherData value is non-zero and includes the base
            // token voteProduct amount.  in this case, use the max of the two
            // values.
            uint256 adjustedVoteProduct = Math.max(rewardTotals.voteProduct, matcherData.nonBaseVoteProduct) -
                matcherData.voteProductDeduction;

            if (adjustedVoteProduct > 0)
                voteMatch = OzMath.mulDiv(
                    matcherData.voteBudget,
                    Math.max(matchReward.nonBaseVoteProduct, rewardValues.voteProduct),
                    adjustedVoteProduct
                );

            totalMatch = voteMatch + incentiveMatch;
        }
        if (totalMatch > 0) {
            // send match to reward and notify
            baseToken.safeTransfer(address(rewardContract), totalMatch);
            rewardContract.notifyRewardAmount(baseToken, NOTIFY_PERIOD);
        }

        emit Distribute(epoch, rewardContract, matcher, baseToken, totalMatch, voteMatch, incentiveMatch);
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function getRolloverBudget(
        uint256 epoch,
        address matcher
    ) public view checkEpoch(epoch) returns (uint256 matchRolloverAmount, uint256 voteRolloverAmount) {
        // can only rollover after vetoing ended
        _checkVetoPeriodEnded(epoch);

        CheckpointData storage checkpoint = checkpoints[epoch];
        EpochInformation storage rewardTotals = checkpoint.dataTotals;

        MatcherData storage matcherData = checkpoint.matcherData[matcher];

        // this matcher's budget - (external incentives - excluded)
        matchRolloverAmount = Math.clip(
            matcherData.matchBudget,
            (matcherData.nonBaseExternalIncentives + rewardTotals.externalIncentives) -
                matcherData.externalIncentivesDeduction
        );

        uint256 effectiveVoteProduct = Math.max(matcherData.nonBaseVoteProduct, rewardTotals.voteProduct) -
            matcherData.voteProductDeduction;

        // if there was zero pro rata product, then none of the vote budget was
        // allocated and all of it can be rolled over. else, voteRollerAmount
        // remains zero.
        if (effectiveVoteProduct == 0) voteRolloverAmount = matcherData.voteBudget;
    }

    /// @inheritdoc IMaverickV2IncentiveMatcher
    function rolloverExcessBudget(
        uint256 matchedEpoch,
        uint256 newEpoch
    )
        public
        checkEpoch(matchedEpoch)
        checkEpoch(newEpoch)
        returns (uint256 matchRolloverAmount, uint256 voteRolloverAmount)
    {
        (matchRolloverAmount, voteRolloverAmount) = getRolloverBudget(matchedEpoch, msg.sender);
        // delete budget account so user can not rollover twice.
        delete checkpoints[matchedEpoch].matcherData[msg.sender];
        emit BudgetRolledOver(msg.sender, matchRolloverAmount, voteRolloverAmount, matchedEpoch, newEpoch);

        // add budgets to new epoch; checks that new epoch is not over yet
        _addBudget(matchRolloverAmount.toUint128(), voteRolloverAmount.toUint128(), newEpoch);
    }
}
