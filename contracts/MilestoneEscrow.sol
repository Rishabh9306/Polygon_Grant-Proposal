// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @title MilestoneEscrow
 * @dev An escrow smart contract for milestone-based crowdfunding on Polygon.
 * This contract allows creators to set funding goals with milestone-based releases.
 * Funds are held in escrow until milestones are verified and approved.
 */
contract MilestoneEscrow is Ownable, ReentrancyGuard, Pausable {
    using Counters for Counters.Counter;
    
    // Campaign statuses
    enum CampaignStatus { Active, Successful, Failed, Cancelled }
    
    // Milestone statuses
    enum MilestoneStatus { Pending, InProgress, Completed, Failed }
    
    // Campaign structure
    struct Campaign {
        address creator;
        string title;
        string description;
        uint256 fundingGoal;
        uint256 totalFundsRaised;
        uint256 deadline;
        uint256 milestoneCount;
        CampaignStatus status;
        bool fundsWithdrawn;
    }
    
    // Milestone structure
    struct Milestone {
        string title;
        string description;
        uint256 fundingPercentage; // Percentage of total funds (1-100)
        uint256 deadline;
        MilestoneStatus status;
        bool fundsReleased;
    }
    
    // Campaign counter
    Counters.Counter private _campaignIds;
    
    // Mappings
    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => mapping(uint256 => Milestone)) public campaignMilestones;
    mapping(uint256 => mapping(address => uint256)) public campaignBackers;
    
    // Events
    event CampaignCreated(uint256 indexed campaignId, address indexed creator, string title, uint256 fundingGoal, uint256 deadline);
    event CampaignFunded(uint256 indexed campaignId, address indexed backer, uint256 amount);
    event MilestoneStarted(uint256 indexed campaignId, uint256 indexed milestoneId);
    event MilestoneCompleted(uint256 indexed campaignId, uint256 indexed milestoneId);
    event MilestoneFailed(uint256 indexed campaignId, uint256 indexed milestoneId);
    event FundsReleased(uint256 indexed campaignId, uint256 indexed milestoneId, uint256 amount);
    event RefundsIssued(uint256 indexed campaignId);
    event CampaignCancelled(uint256 indexed campaignId);
    
    /**
     * @dev Constructor sets the contract owner (platform administrator)
     */
    constructor() Ownable(msg.sender) {
        // Initialize contract
    }
    
    /**
     * @dev Allows a creator to create a new campaign with milestones
     * @param _title Campaign title
     * @param _description Campaign description
     * @param _fundingGoal Total funding goal in wei
     * @param _duration Campaign duration in days
     * @param _milestoneTitles Array of milestone titles
     * @param _milestoneDescriptions Array of milestone descriptions
     * @param _milestoneFundingPercentages Array of funding percentages for each milestone
     * @param _milestoneDurations Array of durations for each milestone in days
     */
    function createCampaign(
        string memory _title,
        string memory _description,
        uint256 _fundingGoal,
        uint256 _duration,
        string[] memory _milestoneTitles,
        string[] memory _milestoneDescriptions,
        uint256[] memory _milestoneFundingPercentages,
        uint256[] memory _milestoneDurations
    ) external whenNotPaused {
        require(_fundingGoal > 0, "Funding goal must be greater than zero");
        require(_duration > 0, "Duration must be greater than zero");
        require(_milestoneTitles.length > 0, "At least one milestone required");
        require(
            _milestoneTitles.length == _milestoneDescriptions.length &&
            _milestoneTitles.length == _milestoneFundingPercentages.length &&
            _milestoneTitles.length == _milestoneDurations.length,
            "Milestone arrays must have the same length"
        );
        
        // Check milestone funding percentages sum to 100%
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < _milestoneFundingPercentages.length; i++) {
            require(_milestoneFundingPercentages[i] > 0, "Milestone funding percentage must be greater than zero");
            totalPercentage += _milestoneFundingPercentages[i];
        }
        require(totalPercentage == 100, "Milestone funding percentages must sum to 100");
        
        // Create new campaign
        _campaignIds.increment();
        uint256 campaignId = _campaignIds.current();
        
        campaigns[campaignId] = Campaign({
            creator: msg.sender,
            title: _title,
            description: _description,
            fundingGoal: _fundingGoal,
            totalFundsRaised: 0,
            deadline: block.timestamp + (_duration * 1 days),
            milestoneCount: _milestoneTitles.length,
            status: CampaignStatus.Active,
            fundsWithdrawn: false
        });
        
        // Create milestones
        uint256 currentDeadline = block.timestamp;
        for (uint256 i = 0; i < _milestoneTitles.length; i++) {
            currentDeadline += (_milestoneDurations[i] * 1 days);
            
            campaignMilestones[campaignId][i] = Milestone({
                title: _milestoneTitles[i],
                description: _milestoneDescriptions[i],
                fundingPercentage: _milestoneFundingPercentages[i],
                deadline: currentDeadline,
                status: i == 0 ? MilestoneStatus.InProgress : MilestoneStatus.Pending,
                fundsReleased: false
            });
        }
        
        emit CampaignCreated(campaignId, msg.sender, _title, _fundingGoal, campaigns[campaignId].deadline);
    }
    
    /**
     * @dev Allow users to fund a campaign
     * @param _campaignId Campaign ID to fund
     */
    function fundCampaign(uint256 _campaignId) external payable whenNotPaused nonReentrant {
        Campaign storage campaign = campaigns[_campaignId];
        
        require(campaign.creator != address(0), "Campaign does not exist");
        require(campaign.status == CampaignStatus.Active, "Campaign is not active");
        require(block.timestamp < campaign.deadline, "Campaign funding has ended");
        require(msg.value > 0, "Funding amount must be greater than zero");
        
        // Update campaign funding
        campaign.totalFundsRaised += msg.value;
        campaignBackers[_campaignId][msg.sender] += msg.value;
        
        emit CampaignFunded(_campaignId, msg.sender, msg.value);
        
        // Check if funding goal reached
        if (campaign.totalFundsRaised >= campaign.fundingGoal) {
            campaign.status = CampaignStatus.Successful;
        }
    }
    
    /**
     * @dev Start the next milestone for a campaign
     * @param _campaignId Campaign ID
     * @param _milestoneId Milestone ID to start
     */
    function startMilestone(uint256 _campaignId, uint256 _milestoneId) external {
        Campaign storage campaign = campaigns[_campaignId];
        
        require(campaign.creator == msg.sender, "Only the campaign creator can start milestones");
        require(campaign.status == CampaignStatus.Successful, "Campaign must be successfully funded");
        require(_milestoneId < campaign.milestoneCount, "Invalid milestone ID");
        
        Milestone storage milestone = campaignMilestones[_campaignId][_milestoneId];
        
        if (_milestoneId > 0) {
            Milestone storage prevMilestone = campaignMilestones[_campaignId][_milestoneId - 1];
            require(prevMilestone.status == MilestoneStatus.Completed, "Previous milestone must be completed");
        }
        
        require(milestone.status == MilestoneStatus.Pending, "Milestone is not pending");
        
        milestone.status = MilestoneStatus.InProgress;
        
        emit MilestoneStarted(_campaignId, _milestoneId);
    }
    
    /**
     * @dev Complete a milestone
     * @param _campaignId Campaign ID
     * @param _milestoneId Milestone ID to complete
     */
    function completeMilestone(uint256 _campaignId, uint256 _milestoneId) external onlyOwner {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Successful, "Campaign must be successfully funded");
        require(_milestoneId < campaign.milestoneCount, "Invalid milestone ID");
        
        Milestone storage milestone = campaignMilestones[_campaignId][_milestoneId];
        require(milestone.status == MilestoneStatus.InProgress, "Milestone must be in progress");
        
        milestone.status = MilestoneStatus.Completed;
        
        emit MilestoneCompleted(_campaignId, _milestoneId);
        
        // Release funds for this milestone to the creator
        releaseMilestoneFunds(_campaignId, _milestoneId);
    }
    
    /**
     * @dev Mark a milestone as failed
     * @param _campaignId Campaign ID
     * @param _milestoneId Milestone ID to fail
     */
    function failMilestone(uint256 _campaignId, uint256 _milestoneId) external onlyOwner {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Successful, "Campaign must be successfully funded");
        require(_milestoneId < campaign.milestoneCount, "Invalid milestone ID");
        
        Milestone storage milestone = campaignMilestones[_campaignId][_milestoneId];
        require(milestone.status == MilestoneStatus.InProgress, "Milestone must be in progress");
        
        milestone.status = MilestoneStatus.Failed;
        campaign.status = CampaignStatus.Failed;
        
        emit MilestoneFailed(_campaignId, _milestoneId);
        
        // Issue refunds for remaining funds
        issueRefunds(_campaignId);
    }
    
    /**
     * @dev Release funds for a completed milestone
     * @param _campaignId Campaign ID
     * @param _milestoneId Milestone ID
     */
    function releaseMilestoneFunds(uint256 _campaignId, uint256 _milestoneId) internal {
        Campaign storage campaign = campaigns[_campaignId];
        Milestone storage milestone = campaignMilestones[_campaignId][_milestoneId];
        
        require(milestone.status == MilestoneStatus.Completed, "Milestone must be completed");
        require(!milestone.fundsReleased, "Funds already released for this milestone");
        
        uint256 amountToRelease = (campaign.totalFundsRaised * milestone.fundingPercentage) / 100;
        milestone.fundsReleased = true;
        
        // Transfer funds to creator
        (bool success, ) = payable(campaign.creator).call{value: amountToRelease}("");
        require(success, "Transfer failed");
        
        emit FundsReleased(_campaignId, _milestoneId, amountToRelease);
    }
    
    /**
     * @dev Issue refunds to backers for remaining funds
     * @param _campaignId Campaign ID
     */
    function issueRefunds(uint256 _campaignId) internal {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Failed, "Campaign must have failed");
        require(!campaign.fundsWithdrawn, "Funds already withdrawn");
        
        campaign.fundsWithdrawn = true;
        
        emit RefundsIssued(_campaignId);
    }
    
    /**
     * @dev Claim refund for a failed campaign
     * @param _campaignId Campaign ID
     */
    function claimRefund(uint256 _campaignId) external nonReentrant {
        Campaign storage campaign = campaigns[_campaignId];
        require(campaign.status == CampaignStatus.Failed, "Campaign must have failed");
        
        uint256 backerAmount = campaignBackers[_campaignId][msg.sender];
        require(backerAmount > 0, "No funds to refund");
        
        // Calculate refund amount based on unreleased milestone funds
        uint256 refundPercentage = 0;
        for (uint256 i = 0; i < campaign.milestoneCount; i++) {
            Milestone storage milestone = campaignMilestones[_campaignId][i];
            if (!milestone.fundsReleased) {
                refundPercentage += milestone.fundingPercentage;
            }
        }
        
        uint256 refundAmount = (backerAmount * refundPercentage) / 100;
        campaignBackers[_campaignId][msg.sender] = 0;
        
        // Transfer refund to backer
        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, "Transfer failed");
    }
    
    /**
     * @dev Cancel a campaign before funding deadline
     * @param _campaignId Campaign ID
     */
    function cancelCampaign(uint256 _campaignId) external {
        Campaign storage campaign = campaigns[_campaignId];
        
        require(campaign.creator == msg.sender || owner() == msg.sender, "Only the campaign creator or owner can cancel");
        require(campaign.status == CampaignStatus.Active, "Campaign is not active");
        
        campaign.status = CampaignStatus.Cancelled;
        
        emit CampaignCancelled(_campaignId);
    }
    
    /**
     * @dev Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Get campaign details
     * @param _campaignId Campaign ID
     * @return Campaign details
     */
    function getCampaign(uint256 _campaignId) external view returns (
        address creator,
        string memory title,
        string memory description,
        uint256 fundingGoal,
        uint256 totalFundsRaised,
        uint256 deadline,
        uint256 milestoneCount,
        CampaignStatus status,
        bool fundsWithdrawn
    ) {
        Campaign storage campaign = campaigns[_campaignId];
        return (
            campaign.creator,
            campaign.title,
            campaign.description,
            campaign.fundingGoal,
            campaign.totalFundsRaised,
            campaign.deadline,
            campaign.milestoneCount,
            campaign.status,
            campaign.fundsWithdrawn
        );
    }
    
    /**
     * @dev Get milestone details
     * @param _campaignId Campaign ID
     * @param _milestoneId Milestone ID
     * @return Milestone details
     */
    function getMilestone(uint256 _campaignId, uint256 _milestoneId) external view returns (
        string memory title,
        string memory description,
        uint256 fundingPercentage,
        uint256 deadline,
        MilestoneStatus status,
        bool fundsReleased
    ) {
        Milestone storage milestone = campaignMilestones[_campaignId][_milestoneId];
        return (
            milestone.title,
            milestone.description,
            milestone.fundingPercentage,
            milestone.deadline,
            milestone.status,
            milestone.fundsReleased
        );
    }
    
    /**
     * @dev Get the total number of campaigns
     * @return Total number of campaigns
     */
    function getCampaignCount() external view returns (uint256) {
        return _campaignIds.current();
    }
    
    /**
     * @dev Get active campaigns
     * @param _start Start index
     * @param _limit Number of campaigns to return
     * @return Array of campaign IDs
     */
    function getActiveCampaigns(uint256 _start, uint256 _limit) external view returns (uint256[] memory) {
        uint256 campaignCount = _campaignIds.current();
        
        // Determine how many campaigns we need to return
        uint256 resultCount = 0;
        for (uint256 i = 1; i <= campaignCount && resultCount < _limit; i++) {
            if (campaigns[i].status == CampaignStatus.Active) {
                resultCount++;
            }
        }
        
        // Create results array
        uint256[] memory result = new uint256[](resultCount);
        uint256 resultIndex = 0;
        
        // Fill results array
        for (uint256 i = _start; i <= campaignCount && resultIndex < resultCount; i++) {
            if (campaigns[i].status == CampaignStatus.Active) {
                result[resultIndex] = i;
                resultIndex++;
            }
        }
        
        return result;
    }
} 