AddCSLuaFile()

ENT.Type = "anim"

function ENT:SetupDataTables()
	self:NetworkVar( "Bool",0, "Disabled" )
	self:NetworkVar( "Bool",1, "CleanMissile" )
	self:NetworkVar( "Bool",2, "DirtyMissile" )
	self:NetworkVar( "Entity",0, "Attacker" )
	self:NetworkVar( "Entity",1, "Inflictor" )
	self:NetworkVar( "Entity",2, "LockOn" )
	self:NetworkVar( "Float",0, "StartVelocity" )
end

if SERVER then

	local lfsRpgDmgMulCvar = CreateConVar( "lfs_missiledamagemul", 1, FCVAR_ARCHIVE )
	local lfsRpgMobilityMul = CreateConVar( "lfs_missilemobilitymul", 1, FCVAR_ARCHIVE )

	local maxBlindfireSpeed = 3000

	sound.Add( {
		name = "lfs_impactflesh",
		channel = CHAN_STATIC,
		volume = 1.0,
		level = 130,
		pitch = { 90, 100 },
		sound = {
			"physics/flesh/flesh_squishy_impact_hard1.wav",
			"physics/flesh/flesh_squishy_impact_hard2.wav",
			"physics/flesh/flesh_squishy_impact_hard3.wav",
			"physics/flesh/flesh_squishy_impact_hard4.wav"
		}
	} )

	function ENT:SpawnFunction( _, tr, ClassName )

		if not tr.Hit then return end

		local ent = ents.Create( ClassName )
		ent:SetPos( tr.HitPos + tr.HitNormal * 20 )
		ent:Spawn()
		ent:Activate()

		return ent

	end

	function ENT:BlindFire()
		if self:GetDisabled() then return end
		if self:DoHitTrace() then return end

		local pObj = self:GetPhysicsObject()

		if IsValid( pObj ) then
			-- ramp up to full speed over a bit less than 1 second
			local timeAlive = math.abs( self:GetCreationTime() - CurTime() )
			local offsettedAlive = timeAlive + 0.1
			local speed = math.Clamp( offsettedAlive * maxBlindfireSpeed, 0, maxBlindfireSpeed )
			local vel = ( speed * lfsRpgMobilityMul:GetFloat() )

			pObj:SetVelocityInstantaneous( self:GetForward() * ( self:GetStartVelocity() + vel ) )
			pObj:SetAngleVelocity( pObj:GetAngleVelocity() * 0.995 ) -- slowly spiral out of a turn
		end
	end

	function ENT:FollowTarget( followent )

		-- increase turnrate the longer missile is alive, bear down on far targets.
		-- goal is to punish pilots/drivers who camp far away from players.
		local timeAlive = math.abs( self:GetCreationTime() - CurTime() )
		local turnrateAdd = math.Clamp( timeAlive * 75, 0, 500 ) * lfsRpgMobilityMul:GetFloat()
		local speedAdd = math.Clamp( timeAlive * 400, 0, 5000 ) * lfsRpgMobilityMul:GetFloat()

		local speed = self:GetStartVelocity() + ( self:GetDirtyMissile() and 4000 or 2500 )
		speed = speed + speedAdd

		local turnrate = ( self:GetCleanMissile() or self:GetDirtyMissile() ) and 30 or 20
		turnrate = turnrate + turnrateAdd

		local TargetPos
		local followsPhysObj = followent:GetPhysicsObject()

		if isfunction( followent.GetMissileOffset ) then
			local Value = followent:GetMissileOffset()
			if isvector( Value ) then
				TargetPos = followent:LocalToWorld( Value )
			end
		elseif IsValid( followsPhysObj ) then
			TargetPos = followent:LocalToWorld( followsPhysObj:GetMassCenter() )
		else
			TargetPos = followent:WorldSpaceCenter()
		end

		local pos = TargetPos + followent:GetVelocity() * 0.15

		local pObj = self:GetPhysicsObject()

		if IsValid( pObj ) and not self:GetDisabled() then
			local myPos = self:GetPos()
			local subtractionProduct = pos - myPos
			local distToTargSqr = subtractionProduct:LengthSqr()
			local targetdir = subtractionProduct:GetNormalized()

			local AF = self:WorldToLocalAngles( targetdir:Angle() )
			local badAngles = AF.p > 110 or AF.y > 110

			if distToTargSqr < 500^2 then
				self:DoHitTrace( myPos )
			-- target is cheating! they're no collided!
			-- if you want to make a plane/vehicle not get targeted by LFS missilelauncher then see LFS.RPGBlockLockon hook, in the launcher
			elseif distToTargSqr < 75^2 then
				self:HitEntity( followent )
				return
			-- target escaped!
			elseif badAngles then
				self:SetLockOn( nil )
				return
			end

			AF.p = math.Clamp( AF.p * 400,-turnrate,turnrate )
			AF.y = math.Clamp( AF.y * 400,-turnrate,turnrate )
			AF.r = math.Clamp( AF.r * 400,-turnrate,turnrate )

			local AVel = pObj:GetAngleVelocity()
			pObj:AddAngleVelocity( Vector( AF.r,AF.p,AF.y ) - AVel )

			pObj:SetVelocityInstantaneous( self:GetForward() * speed )
		end
	end

	function ENT:Initialize()
		self:SetModel( "models/weapons/w_missile_launch.mdl" )
		self:PhysicsInit( SOLID_VPHYSICS )
		self:SetMoveType( MOVETYPE_VPHYSICS )
		self:SetSolid( SOLID_VPHYSICS )
		self:SetRenderMode( RENDERMODE_TRANSALPHA )
		self:PhysWake()
		local pObj = self:GetPhysicsObject()

		if IsValid( pObj ) then
			pObj:EnableGravity( false )
			pObj:SetMass( 1 )
		end

		self.SpawnTime = CurTime()
	end

	function ENT:Think()
		local curtime = CurTime()
		self:NextThink( curtime )

		local Target = self:GetLockOn()
		if IsValid( Target ) then
			self:FollowTarget( Target )
		else
			self:BlindFire()
		end

		if ( self.SpawnTime + 12 ) < curtime then
			self:Detonate()
		end

		return true
	end

	function ENT:PhysicsCollide( data )
		if self:GetDisabled() then
			self:Detonate()
		else
			local HitEnt = data.HitEntity

			self:HitEntity( HitEnt )
		end
	end

	local missileHitboxMax = Vector( 10, 10, 10 )
	local missileHitboxMins = -missileHitboxMax

	function ENT:DoHitTrace( myPos )
		local startPos = myPos or self:GetPos()
		local offset = self:GetForward() * 20
		local inflic = self:GetInflictor()

		local trResult = util.TraceHull( {
			start = startPos,
			endpos = startPos + offset,
			filter = { self, self:GetOwner(), inflic },
			maxs = missileHitboxMax,
			mins = missileHitboxMins,
			mask = MASK_SOLID,
		} )

		if trResult.Hit then
			-- dont hit sub-ents of the inflictor
			if IsValid( inflic ) and IsValid( trResult.Entity:GetParent() ) and trResult.Entity:GetParent() == inflic then return end
			self:HitEntity( trResult.Entity )
			return true
		end
	end

	function ENT:GetDirectHitDamage( HitEnt )
		local hookResultDmg, hookResultSound = hook.Run( "LFS.MissileDirectHitDamage", self, HitEnt )
		if hookResultDmg ~= nil and isnumber( hookResultDmg ) then return hookResultDmg, hookResultSound end

		local dmgAmount = 600
		local dmgSound = "Missile.ShotDown"

		if HitEnt.IsSimfphyscar then
			dmgAmount = 1000
		elseif HitEnt:IsNPC() or HitEnt:IsNextBot() then
			dmgAmount = 100
			dmgSound = "lfs_impactflesh"
		elseif HitEnt:IsPlayer() then
			-- this ends up getting added with the blastdamage, doesn't need to be too strong
			dmgAmount = 50
			dmgSound = "lfs_impactflesh"
		end

		return dmgAmount, dmgSound
	end

	function ENT:HitEntity( HitEnt )
		if IsValid( HitEnt ) then
			local Pos = self:GetPos()
			-- hit simfphys car instead of simfphys wheel
			if HitEnt.GetBaseEnt and IsValid( HitEnt:GetBaseEnt() ) then
				HitEnt = HitEnt:GetBaseEnt()
			end

			local effectdata = EffectData()
				effectdata:SetOrigin( Pos )
				effectdata:SetNormal( -self:GetForward() )
			util.Effect( "manhacksparks", effectdata, true, true )

			local dmgAmount, dmgSound = self:GetDirectHitDamage( HitEnt )

			local dmginfo = DamageInfo()
				dmginfo:SetDamage( dmgAmount * lfsRpgDmgMulCvar:GetFloat() )
				dmginfo:SetAttacker( IsValid( self:GetAttacker() ) and self:GetAttacker() or self )
				dmginfo:SetDamageType( DMG_DIRECT )
				dmginfo:SetInflictor( self )
				dmginfo:SetDamagePosition( Pos )
			HitEnt:TakeDamageInfo( dmginfo )

			sound.Play( dmgSound, Pos, 140 )

		end

		self:Detonate()
	end

	function ENT:BreakMissile()
		if not self:GetDisabled() then
			self:SetDisabled( true )

			local pObj = self:GetPhysicsObject()

			if IsValid( pObj ) then
				pObj:EnableGravity( true )
				self:PhysWake()
				self:EmitSound( "Missile.ShotDown" )
			end
		end
	end

	function ENT:Detonate()
		local dmgMul = lfsRpgDmgMulCvar:GetFloat()

		local Inflictor = self:GetInflictor()
		local Attacker = self:GetAttacker()

		local ExplodePos = self:WorldSpaceCenter()

		local effectdata = EffectData()
			effectdata:SetOrigin( self:GetPos() )
		util.Effect( "lfs_missile_explosion", effectdata )

		self:Remove()

		timer.Simple( 0, function()
			local FallbackDamager = Entity( 0 )
			Inflictor = IsValid( Inflictor ) and Inflictor or FallbackDamager
			Attacker = IsValid( Attacker ) and Attacker or FallbackDamager

			util.BlastDamage( Inflictor, Attacker, ExplodePos, 200 * dmgMul, 100 * dmgMul )
		end )
	end

	function ENT:OnTakeDamage( dmginfo )
		if dmginfo:GetDamageType() ~= DMG_AIRBOAT then return end

		if self:GetAttacker() == dmginfo:GetAttacker() then return end

		self:BreakMissile()
	end
else
	function ENT:Initialize()
		self.snd = CreateSound( self, "weapons/flaregun/burn.wav" )
		self.snd:Play()

		local effectdata = EffectData()
			effectdata:SetOrigin( self:GetPos() )
			effectdata:SetEntity( self )
		util.Effect( "lfs_missile_trail", effectdata, true, true )
	end

	function ENT:Draw()
		self:DrawModel()
	end

	function ENT:SoundStop()
		if self.snd then
			self.snd:Stop()
		end
	end

	function ENT:Think()
		if self:GetDisabled() then
			self:SoundStop()
		end

		return true
	end

	function ENT:OnRemove()
		self:SoundStop()
	end
end